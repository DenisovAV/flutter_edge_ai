import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/advisor_model_service.dart';
import '../advisor/advisor_surface.dart';
import '../advisor/stage.dart';
import '../models/model_catalog.dart';
import '../search/search_service.dart';
import 'chat_state.dart';
import 'edge_ai_chat_driver.dart';
import 'external_tools.dart';
import 'prompt_assets.dart';
import 'starters.dart';

export 'chat_state.dart';

/// Factory seam so tests can inject a scripted [ChatDriver].
typedef ChatDriverFactory = Future<ChatDriver> Function(String systemInstruction);

final chatDriverFactoryProvider = Provider<ChatDriverFactory?>((ref) => null);

/// How long a turn may go with no event (no token, no tool) before the app
/// stops it. Null disables it (tests). Generous for the emulator's CPU; a
/// phone should trip this far less often.
final turnIdleLimitProvider = Provider<Duration?>((ref) => const Duration(seconds: 75));

final chatServiceProvider = NotifierProvider<ChatService, ChatState>(ChatService.new);

class ChatService extends Notifier<ChatState> {
  TurnPipeline? _pipeline;
  ChatDriver? _driver;

  @override
  ChatState build() {
    ref.onDispose(() => _driver?.close());
    return const ChatState();
  }

  /// Opens a chat on the active model. Call again to start a new conversation.
  Future<void> start() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final builder = await ref.read(promptAssetsProvider.future);
      final profile = _pipeline?.profile ?? const BuyerProfile();
      final instruction = builder.build(profile: profile);
      final factory = ref.read(chatDriverFactoryProvider);
      ChatDriver driver;
      if (factory != null) {
        driver = await factory(instruction);
      } else {
        final models = ref.read(advisorModelServiceProvider.notifier);
        final model = models.loadedModel;
        final activeId = ref.read(advisorModelServiceProvider).value?.activeId;
        final spec = activeId == null ? null : ModelCatalog.byId(activeId);
        if (model == null || spec == null) {
          state = state.copyWith(
            busy: false,
            error: 'No model is loaded. Open Models and choose one.',
          );
          return;
        }
        driver = await EdgeAiChatDriver.open(model, spec, systemInstruction: instruction);
      }
      await _driver?.close();
      _driver = driver;
      _pipeline = TurnPipeline(driver: driver, profile: profile, external: ExternalTools(ref).call);
      state = ChatState(ready: true, timeline: [ComponentEntry(Starters.openingPrompt(profile))]);
      // Every applied search becomes a line in the conversation, so the
      // transcript shows what the person chose and the model can be told.
      ref.read(searchProvider.notifier).onApplied = (s) {
        final line =
            'Looking for ${s.query.describe()} on ${CuratedSites.byId(s.siteId)?.name ?? s.siteId}: ${s.lastCount ?? 0} listings read.';
        final t = [...state.timeline];
        // One note per run of searches (Q65): a consecutive note is replaced,
        // an identical one is skipped, so the transcript never repeats itself.
        if (t.isNotEmpty &&
            t.last is MessageEntry &&
            (t.last as MessageEntry).message.role == MessageRole.system &&
            (t.last as MessageEntry).message.text.startsWith('Looking for')) {
          if ((t.last as MessageEntry).message.text == line) return;
          t.removeLast();
        }
        state = state.copyWith(
          timeline: [
            ...t,
            MessageEntry(ChatMessage(role: MessageRole.system, text: line)),
          ],
        );
      };
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Could not start Motormind: $e');
    }
  }

  void _replaceEntry(int index, TimelineEntry entry) {
    final t = [...state.timeline];
    t[index] = entry;
    state = state.copyWith(timeline: t);
  }

  /// [filtersCardComing] is set by [choose] when the filters card is about to
  /// join the conversation, so the first turn already knows it is on screen.
  Future<void> send(String text, {bool filtersCardComing = false}) async {
    final pipeline = _pipeline;
    if (pipeline == null || state.busy || text.trim().isEmpty) return;
    final userMsg = ChatMessage(role: MessageRole.user, text: text.trim());
    var reply = const ChatMessage(role: MessageRole.motormind, text: '', streaming: true);
    // The obvious filters in a sentence ("a Honda sports car under 40k") apply
    // before the model has read it, so the page is already changing.
    ref.read(searchProvider.notifier).updateFromText(text);
    // The model is told the current search (it cannot see the card); the
    // bubble shows only what the person typed.
    final search = ref.read(searchProvider);
    final hasFiltersCard =
        filtersCardComing ||
        state.timeline.any(
          (e) => e is ComponentEntry && e.shown.request.component.id == 'search_filters',
        );
    final siteName = CuratedSites.byId(search.siteId)?.name ?? search.siteId;
    final searchContext = !hasFiltersCard
        ? ''
        : search.query.isEmpty
        ? '\n\n[A filter card (vehicle type, price, miles, site) is on screen; nothing set yet, '
              'site $siteName. Do not ask what kind or what price; they can tap or tell you.]'
        : '\n\n[Already set on the filter card: ${search.query.describe()} on $siteName; '
              '${search.lastCount ?? 0} listings read. Do not ask about these again.]';
    state = state.copyWith(
      timeline: [...state.timeline, MessageEntry(userMsg), MessageEntry(reply)],
      busy: true,
      clearGuardNote: true,
      clearError: true,
      policyFlags: const [],
      turnStartedAt: DateTime.now(),
    );
    var replyIndex = state.timeline.length - 1;
    void updateReply(ChatMessage m) {
      reply = m;
      _replaceEntry(replyIndex, MessageEntry(m));
    }

    try {
      final idleLimit = ref.read(turnIdleLimitProvider);
      Timer? watchdog;
      var stoppedByWatchdog = false;
      void arm() {
        watchdog?.cancel();
        if (idleLimit == null) return;
        watchdog = Timer(idleLimit, () async {
          stoppedByWatchdog = true;
          await _driver?.cancel();
        });
      }

      arm();
      debugPrint('[motormind] turn start');
      await for (final e in pipeline.run(text.trim() + searchContext)) {
        arm();
        switch (e) {
          case TextDelta(:final text):
            updateReply(reply.copyWith(text: reply.text + text));
          case ThinkingDelta():
            break;
          case ToolStarted(:final name):
            debugPrint('[motormind] tool $name');
            state = state.copyWith(activeTool: name);
          case ToolFinished():
            state = state.copyWith(clearActiveTool: true);
          case ProfileUpdated():
            break;
          case Presented(:final request, :final result):
            final surface = ref.read(surfaceProvider);
            final toStage =
                !request.component.isInteraction &&
                surface != SurfaceState.fullscreen &&
                request.surface != SurfaceState.fullscreen;
            final shown = ShownComponent(request: request, result: result);
            if (toStage) {
              ref.read(stageProvider.notifier).show(shown);
            } else {
              // Replace an earlier card for the same result (auto-present then
              // the model's own present), else insert above the reply.
              final t = [...state.timeline];
              final existing = result == null
                  ? -1
                  : t.indexWhere((e) => e is ComponentEntry && e.shown.result?.id == result.id);
              if (existing >= 0) {
                t[existing] = ComponentEntry(shown);
              } else {
                t.insert(replyIndex, ComponentEntry(shown));
                replyIndex += 1;
              }
              state = state.copyWith(timeline: t);
            }
            if (request.surface == SurfaceState.fullscreen) {
              ref.read(surfaceProvider.notifier).request(SurfaceState.fullscreen);
            }
          case InputRejected(:final arguments):
            state = state.copyWith(
              guardNote:
                  'Refused a calculation: ${arguments.join(', ')} was not something you told me.',
            );
          case PresentRejected():
            state = state.copyWith(clearActiveTool: true);
          case GuardTripped(:final report, :final replaced):
            state = state.copyWith(
              guardNote: replaced
                  ? 'Motormind\'s wording was replaced because it contained numbers not from a calculation.'
                  : 'Checking numbers: ${report.unmatched.map((m) => m.raw).join(', ')}',
            );
            if (replaced) updateReply(reply.copyWith(text: ''));
          case PolicyFlagged(:final flags):
            state = state.copyWith(policyFlags: flags);
          case TurnDone(:final narration, :final results):
            // Gemma sometimes ends a turn right after a tool call with no
            // words. The screen must still answer, so the app writes the
            // sentence from what it knows (counts, not the model's numbers).
            final text = narration.trim().isNotEmpty ? narration : _silentTurnText(results);
            updateReply(reply.copyWith(text: text, streaming: false));
        }
      }
      watchdog?.cancel();
      if (stoppedByWatchdog) {
        state = state.copyWith(
          error:
              'Stopped: Motormind went ${idleLimit!.inSeconds} seconds without a word. Try a shorter message.',
        );
      }
    } catch (e) {
      final msg = _friendly(e);
      updateReply(reply.copyWith(text: reply.text.isEmpty ? msg : reply.text, streaming: false));
      state = state.copyWith(error: msg);
    } finally {
      debugPrint('[motormind] turn done');
      state = state.copyWith(busy: false, clearActiveTool: true, clearTurnStartedAt: true);
    }
  }

  String _silentTurnText(List<ToolResult> results) {
    final searched = results.any(
      (r) => r.tool == AdvisorTools.findVehicles || r.tool == AdvisorTools.updateSearch,
    );
    if (searched) {
      final s = ref.read(searchProvider);
      final site = CuratedSites.byId(s.siteId)?.name ?? s.siteId;
      final n = s.lastCount ?? 0;
      if (n == 0) {
        return 'Nothing on $site matched ${s.query.describe()}. Loosen a filter or try another site.';
      }
      return '$n listings on $site match ${s.query.describe()}. Tap a type or price to narrow it, or tell me more.';
    }
    if (results.isNotEmpty) return 'Here is what I found. Tell me more when you are ready.';
    return 'Nothing to add yet. Pick an option above, change a filter, or tell me more.';
  }

  /// Cancels the generation in flight; whatever was produced so far stays
  /// (cards, partial text). The person can type a new prompt (Q58).
  Future<void> interrupt() async {
    await _driver?.cancel();
  }

  /// Answer a choice prompt or a form. [supplement] is text the person typed
  /// alongside the selection (Q60): it is sent with the selection. Opening-mode
  /// choices set the mode locally and put a starter on the stage before the
  /// model answers. [source] is the card answered; it is marked answered but
  /// stays visible.
  Future<void> choose(String id, String label, {String? supplement, ShownComponent? source}) async {
    if (source != null) {
      ref.read(stageProvider.notifier).markAnswered(source);
      final t = [
        for (final e in state.timeline)
          if (e is ComponentEntry && identical(e.shown, source))
            ComponentEntry(source.copyWith(answered: true))
          else
            e,
      ];
      state = state.copyWith(timeline: t);
    }
    final extra = (supplement ?? '').trim();
    String withExtra(String text) => extra.isEmpty ? text : '$text $extra';
    final opening = Starters.openingChoices[id];
    if (opening != null) {
      final (mode, sentence) = opening;
      _pipeline?.profile = (_pipeline?.profile ?? const BuyerProfile()).applyUpdate({
        'shopping_mode': mode.name,
      });
      // The live filters join the conversation the moment a mode is chosen, so
      // the screen responds before the model has said a word (Q43, DD
      // principle 3). The card is app-owned: it tracks the search state.
      // send() is synchronous up to its first await, so the card lands after
      // the sentence and before the reply bubble fills in.
      final turn = send(withExtra(sentence), filtersCardComing: true);
      if (!state.timeline.any(
        (e) => e is ComponentEntry && e.shown.request.component.id == 'search_filters',
      )) {
        state = state.copyWith(
          timeline: [
            ...state.timeline,
            ComponentEntry(Starters.filtersCard()),
            // Mode starters (Q64, Q66): the app says what it did and asks,
            // so the person can correct it instead of living with a default.
            if (Starters.forMode(mode) case final starter?) ComponentEntry(starter),
            const MessageEntry(
              ChatMessage(role: MessageRole.system, text: Starters.negotiableNote),
            ),
          ],
        );
      }
      return turn;
    }
    if (id.startsWith(Starters.kindPrefix)) {
      final style = SearchQuery.normalizeBodyStyle(id.substring(Starters.kindPrefix.length));
      if (style != null) ref.read(searchProvider.notifier).update({'body_style': style});
      return send(
        withExtra(
          id == 'kind-unsure'
              ? 'I am not sure what kind of vehicle yet.'
              : 'I am looking at a $label.',
        ),
      );
    }
    return send(withExtra(label));
  }

  BuyerProfile get profile => _pipeline?.profile ?? const BuyerProfile();

  static String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('exceeds available state') || s.contains('context')) {
      return 'The conversation grew past what this model can hold in memory. Start a new conversation to continue.';
    }
    if (e is TimeoutException) return e.message ?? 'Motormind took too long to answer.';
    return 'Something went wrong: $s';
  }
}
