import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/advisor_model_service.dart';
import '../../services/log.dart';
import '../advisor/advisor_surface.dart';
import '../advisor/stage.dart';
import '../listings/listing_signals.dart';
import '../models/model_catalog.dart';
import '../search/search_service.dart';
import 'chat_state.dart';
import 'chat_strings.dart';
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

  /// The turn in flight, so an interrupt can wait for it to wind down.
  Future<void>? _turn;

  @override
  ChatState build() {
    ref.onDispose(() => _driver?.close());
    // Every applied search becomes one note in the conversation, so the
    // transcript shows what the person chose. A consecutive note is replaced
    // and an identical one skipped, so the transcript never repeats itself.
    ref.listen(searchProvider, (previous, next) {
      if (!state.ready || next.applying || next.lastCount == null) return;
      if (previous?.lastCount == next.lastCount && previous?.query == next.query) return;
      _noteSearch(next);
    });
    return const ChatState();
  }

  void _noteSearch(SearchState s) {
    final line = ChatStrings.searchNote(s.query.describe(), s.siteName, s.lastCount ?? 0);
    final t = [...state.timeline];
    final last = t.lastOrNull;
    if (last is MessageEntry &&
        last.message.role == MessageRole.system &&
        last.message.isSearchNote) {
      if (last.message.text == line) return;
      t.removeLast();
    }
    state = state.copyWith(timeline: [...t, MessageEntry(ChatMessage.searchNote(line))]);
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
          state = state.copyWith(busy: false, error: ChatStrings.noModel);
          return;
        }
        // Close the previous chat before opening the next so two sessions
        // never sit in device memory at once.
        await _driver?.close();
        _driver = null;
        driver = await EdgeAiChatDriver.open(model, spec, systemInstruction: instruction);
      }
      await _driver?.close();
      _driver = driver;
      _pipeline = TurnPipeline(driver: driver, profile: profile, external: ExternalTools(ref).call);
      // A fresh conversation: every flag from the previous one is dropped.
      state = ChatState(ready: true, timeline: [ComponentEntry(Starters.openingPrompt(profile))]);
    } on Exception catch (e) {
      logDev('start failed: $e');
      state = state.copyWith(busy: false, error: ChatStrings.startFailed);
    }
  }

  void _replaceEntry(int index, TimelineEntry entry) {
    final t = [...state.timeline];
    t[index] = entry;
    state = state.copyWith(timeline: t);
  }

  /// [filtersCardComing] is set by [choose] when the filters card is about to
  /// join the conversation, so the first turn already knows it is on screen.
  Future<void> send(String text, {bool filtersCardComing = false}) {
    final pipeline = _pipeline;
    if (pipeline == null || state.busy || text.trim().isEmpty) return Future.value();
    return _turn = _runTurn(pipeline, text, filtersCardComing: filtersCardComing);
  }

  Future<void> _runTurn(
    TurnPipeline pipeline,
    String text, {
    required bool filtersCardComing,
  }) async {
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
    final siteName = CuratedSites.nameFor(search.siteId);
    final signals = ref.read(listingSignalsProvider.notifier).summary(_listingsOnStage());
    final signalContext = signals == null ? '' : '\n[Listings: $signals.]';
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
      logDev('turn start');
      await for (final e in pipeline.run(text.trim() + searchContext + signalContext)) {
        arm();
        switch (e) {
          case TextDelta(:final text):
            updateReply(reply.copyWith(text: reply.text + text));
          case ThinkingDelta():
            break;
          case ToolStarted(:final name):
            logDev('tool $name');
            state = state.copyWith(activeTool: name);
          case ToolFinished():
            state = state.copyWith(clearActiveTool: true);
          case ProfileUpdated():
            break;
          case Presented(:final result, automatic: true)
              when result?.tool == AdvisorTools.findVehicles:
            // The live search already put this result on the stage.
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
            state = state.copyWith(guardNote: ChatStrings.refusedInputs(arguments));
          case PresentRejected():
            state = state.copyWith(clearActiveTool: true);
          case GuardTripped(:final report, :final replaced):
            state = state.copyWith(
              guardNote: replaced
                  ? ChatStrings.numbersReplaced
                  : ChatStrings.checkingNumbers(report.unmatched.map((m) => m.raw)),
            );
            if (replaced) updateReply(reply.copyWith(text: ''));
          case PolicyFlagged(:final flags):
            state = state.copyWith(policyFlags: flags);
          case NarrationReplaced(:final text):
            // The guard or the prose-list conversion rewrote the reply; what
            // streamed so far is replaced, not appended to, and the note no
            // longer quotes the numbers that were taken out.
            updateReply(reply.copyWith(text: text));
            if (state.guardNote != null) {
              state = state.copyWith(guardNote: ChatStrings.numbersReplaced);
            }
          case TurnFailed(:final message):
            logDev('turn failed inside the pipeline: $message');
            state = state.copyWith(error: ChatStrings.somethingWrong);
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
        state = state.copyWith(error: ChatStrings.stoppedAfter(idleLimit!.inSeconds));
      }
    } on Exception catch (e) {
      logDev('turn failed: $e');
      final msg = _friendly(e);
      updateReply(reply.copyWith(text: reply.text.isEmpty ? msg : reply.text, streaming: false));
      state = state.copyWith(error: msg);
    } finally {
      logDev('turn done');
      state = state.copyWith(busy: false, clearActiveTool: true, clearTurnStartedAt: true);
    }
  }

  /// The listings currently on the stage, as the maps the cards render from.
  List<Map<String, Object?>> _listingsOnStage() => [
    for (final c in ref.read(stageProvider).cards)
      if (c.request.component.id == 'vehicle_card')
        ...((c.result?.result?['listings'] as List?) ?? const []).map(
          (l) => (l as Map).cast<String, Object?>(),
        ),
  ];

  String _silentTurnText(List<ToolResult> results) {
    final searched = results.any(
      (r) => r.tool == AdvisorTools.findVehicles || r.tool == AdvisorTools.updateSearch,
    );
    if (searched) {
      final s = ref.read(searchProvider);
      final n = s.lastCount ?? 0;
      if (n == 0) return ChatStrings.noMatches(s.siteName, s.query.describe());
      return ChatStrings.matches(n, s.siteName, s.query.describe());
    }
    if (results.isNotEmpty) return ChatStrings.hereIsWhatIFound;
    return ChatStrings.nothingToAdd;
  }

  /// Cancels the generation in flight and waits for the turn to wind down;
  /// whatever was produced so far stays (cards, partial text). The person
  /// can type a new prompt at once (Q58).
  Future<void> interrupt() async {
    await _driver?.cancel();
    await _turn;
  }

  /// Dismisses the sales-language banner.
  void clearPolicyFlags() => state = state.copyWith(policyFlags: const []);

  /// Answers a choice prompt or a form. [supplement] is text the person typed
  /// alongside the selection (Q60): it is sent with the selection. Opening-mode
  /// choices set the mode locally and add the filters card and a starter to
  /// the conversation before the model answers. [source] is the card
  /// answered; it collapses to its question but stays in the transcript.
  Future<void> choose(String id, String label, {String? supplement, ShownComponent? source}) async {
    // While a turn runs, a tap would be retired and then dropped by send();
    // refusing it up front keeps the chips live for after the turn.
    if (_pipeline == null || state.busy) return;
    if (source != null) {
      ref.read(stageProvider.notifier).markAnswered(source);
      final t = [
        for (final e in state.timeline)
          if (e is ComponentEntry && e.shown.id == source.id)
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
      return send(withExtra('I am looking at a $label.'));
    }
    return send(withExtra(label));
  }

  BuyerProfile get profile => _pipeline?.profile ?? const BuyerProfile();

  /// The engine's context-window overflow message, the one failure the
  /// person can act on (start a new conversation).
  static final _contextOverflow = RegExp(r'exceeds available state|context (window|length)');

  static String _friendly(Object e) {
    if (e is TimeoutException) return e.message ?? ChatStrings.tooLong;
    if (_contextOverflow.hasMatch(e.toString())) return ChatStrings.contextFull;
    return ChatStrings.somethingWrong;
  }
}
