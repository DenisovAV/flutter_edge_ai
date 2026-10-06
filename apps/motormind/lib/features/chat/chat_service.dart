import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/advisor_model_service.dart';
import '../advisor/advisor_surface.dart';
import '../advisor/stage.dart';
import '../browser/browser_service.dart';
import '../models/model_catalog.dart';
import '../search/search_service.dart';
import 'edge_ai_chat_driver.dart';

/// One rendered message in the transcript.
class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.streaming = false});

  final String role; // 'user' | 'advisor' | 'system' (a note in the transcript)
  final String text;
  final bool streaming;

  ChatMessage copyWith({String? text, bool? streaming}) =>
      ChatMessage(role: role, text: text ?? this.text, streaming: streaming ?? this.streaming);
}

/// A card or prompt the model (or the app) asked to show.
class ShownComponent {
  const ShownComponent({required this.request, this.result, this.answered = false});
  final PresentRequest request;
  final ToolResult? result;

  /// True once the person answered an interaction component; it then renders
  /// collapsed so the conversation keeps its history without live buttons.
  final bool answered;

  ShownComponent copyWith({bool? answered}) =>
      ShownComponent(request: request, result: result, answered: answered ?? this.answered);
}

/// Messages and components interleaved in the order they happened.
sealed class TimelineEntry {
  const TimelineEntry();
}

class MessageEntry extends TimelineEntry {
  const MessageEntry(this.message);
  final ChatMessage message;
}

class ComponentEntry extends TimelineEntry {
  const ComponentEntry(this.shown);
  final ShownComponent shown;
}

/// Everything the chat panel renders.
class ChatState {
  const ChatState({
    this.timeline = const [],
    this.activeTool,
    this.busy = false,
    this.policyFlags = const [],
    this.guardNote,
    this.error,
    this.ready = false,
    this.turnStartedAt,
  });

  final List<TimelineEntry> timeline;
  final String? activeTool;
  final bool busy;
  final List<PolicyFlag> policyFlags;
  final String? guardNote;
  final String? error;
  final bool ready;

  /// When the current turn began; null when idle. The panel shows elapsed time.
  final DateTime? turnStartedAt;

  List<ChatMessage> get messages => [
    for (final e in timeline)
      if (e is MessageEntry) e.message,
  ];
  List<ShownComponent> get shown => [
    for (final e in timeline)
      if (e is ComponentEntry) e.shown,
  ];

  ChatState copyWith({
    List<TimelineEntry>? timeline,
    String? activeTool,
    bool clearActiveTool = false,
    bool? busy,
    List<PolicyFlag>? policyFlags,
    String? guardNote,
    bool clearGuardNote = false,
    String? error,
    bool clearError = false,
    bool? ready,
    DateTime? turnStartedAt,
    bool clearTurnStartedAt = false,
  }) => ChatState(
    timeline: timeline ?? this.timeline,
    activeTool: clearActiveTool ? null : (activeTool ?? this.activeTool),
    busy: busy ?? this.busy,
    policyFlags: policyFlags ?? this.policyFlags,
    guardNote: clearGuardNote ? null : (guardNote ?? this.guardNote),
    error: clearError ? null : (error ?? this.error),
    ready: ready ?? this.ready,
    turnStartedAt: clearTurnStartedAt ? null : (turnStartedAt ?? this.turnStartedAt),
  );
}

/// Factory seam so tests can inject a scripted [ChatDriver].
typedef ChatDriverFactory = Future<ChatDriver> Function(String systemInstruction);

final chatDriverFactoryProvider = Provider<ChatDriverFactory?>((ref) => null);

/// How long a turn may go with no event (no token, no tool) before the app
/// stops it. Null disables it (tests). Generous for the emulator's CPU; a
/// phone should trip this far less often.
final turnIdleLimitProvider = Provider<Duration?>((ref) => const Duration(seconds: 75));

final promptAssetsProvider = FutureProvider<SystemPromptBuilder>((ref) async {
  final persona = await rootBundle.loadString('assets/prompts/persona.md');
  final policy = await rootBundle.loadString('assets/prompts/policy.md');
  final modes = await rootBundle.loadString('assets/prompts/modes.md');
  return SystemPromptBuilder(persona: persona, policy: policy, modeGuidance: _parseModes(modes));
});

Map<ShoppingMode, String> _parseModes(String md) {
  final out = <ShoppingMode, String>{};
  ShoppingMode? current;
  final buf = StringBuffer();
  void flush() {
    final mode = current;
    if (mode != null) out[mode] = buf.toString().trim();
    buf.clear();
  }

  for (final line in md.split('\n')) {
    if (line.startsWith('# ')) {
      flush();
      final name = line.substring(2).trim();
      current = ShoppingMode.values.where((m) => m.name == name).firstOrNull;
    } else {
      buf.writeln(line);
    }
  }
  flush();
  return out;
}

/// The opening prompt (Q43): the app, not the model, offers the shopping-mode
/// choice so the first screen demonstrates structured interaction without a
/// model round trip. Answering sets the mode locally and tells the model.
const Map<String, (ShoppingMode, String)> openingChoices = {
  'mode-browsing': (ShoppingMode.browsing, 'I\'m just looking for now.'),
  'mode-practical': (ShoppingMode.practical, 'I want practical options that fit my budget.'),
  'mode-buying': (ShoppingMode.buying, 'I\'m buying now and want to work through the numbers.'),
  'mode-dreaming': (ShoppingMode.dreaming, 'Let\'s have some fun and look at a dream car.'),
};

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
      _pipeline = TurnPipeline(driver: driver, profile: profile, external: _externalTool);
      state = ChatState(ready: true, timeline: [ComponentEntry(_openingPrompt(profile))]);
      // Every applied search becomes a line in the conversation, so the
      // transcript shows what the person chose and the model can be told.
      ref.read(searchProvider.notifier).onApplied = (s) {
        final line =
            'Looking for ${s.query.describe()} on ${CuratedSites.byId(s.siteId)?.name ?? s.siteId}: ${s.lastCount ?? 0} listings read.';
        state = state.copyWith(
          timeline: [
            ...state.timeline,
            MessageEntry(ChatMessage(role: 'system', text: line)),
          ],
        );
      };
    } catch (e) {
      state = state.copyWith(busy: false, error: 'Could not start the advisor: $e');
    }
  }

  ShownComponent _filtersCard() {
    final v = PresentRequest.validate({'component': 'search_filters'}, resultTool: null);
    return ShownComponent(request: v.request!);
  }

  ShownComponent _openingPrompt(BuyerProfile profile) {
    final v = PresentRequest.validate({
      'component': 'choice',
      'props': {
        'question': profile.mode == null
            ? 'How are you shopping today?'
            : 'Pick up where you left off, or change how you\'re shopping:',
        'options': [
          {'id': 'mode-browsing', 'label': 'Just looking'},
          {'id': 'mode-practical', 'label': 'Practical options'},
          {'id': 'mode-buying', 'label': 'Buying now'},
          {'id': 'mode-dreaming', 'label': 'Dream car'},
        ],
      },
    }, resultTool: null);
    return ShownComponent(request: v.request!);
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
    final userMsg = ChatMessage(role: 'user', text: text.trim());
    var reply = const ChatMessage(role: 'advisor', text: '', streaming: true);
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
                  ? 'The advisor\'s wording was replaced because it contained numbers not from a calculation.'
                  : 'Checking numbers: ${report.unmatched.map((m) => m.raw).join(', ')}',
            );
            if (replaced) updateReply(reply.copyWith(text: ''));
          case PolicyFlagged(:final flags):
            state = state.copyWith(policyFlags: flags);
          case TurnDone(:final narration):
            updateReply(reply.copyWith(text: narration, streaming: false));
        }
      }
      watchdog?.cancel();
      if (stoppedByWatchdog) {
        state = state.copyWith(
          error:
              'Stopped: the advisor went ${idleLimit!.inSeconds} seconds without a word. Try a shorter message.',
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
    final opening = openingChoices[id];
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
        state = state.copyWith(timeline: [...state.timeline, ComponentEntry(_filtersCard())]);
      }
      return turn;
    }
    if (id.startsWith('kind-')) {
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

  /// Tools the pipeline does not own: the web pane and the session listings.
  Future<Map<String, Object?>> _externalTool(String name, Map<String, Object?> args) async {
    switch (name) {
      case AdvisorTools.readPage:
        final url = args['url']?.toString();
        ref.read(stageProvider.notifier).showWeb();
        final PageExtract extract;
        try {
          extract = await ref.read(browserProvider.notifier).readPage(url: url);
        } on PageChallengeException catch (e) {
          return {'error': e.toString()};
        }
        final facts = extractFacts(extract.text);
        return {
          'url': extract.url,
          'title': extract.title,
          'text': extract.text.length > 1500 ? '${extract.text.substring(0, 1500)}…' : extract.text,
          'facts': facts,
          'listings': [for (final l in extract.listings.take(8)) l.toModelJson()],
        };
      case AdvisorTools.updateSearch:
      case AdvisorTools.findVehicles:
        // Both go through the live search: the chosen site, the current
        // filters plus what the model passed, one visible page, read once.
        final search = ref.read(searchProvider.notifier);
        final changes = <String, Object?>{
          for (final k in const [
            'body_style',
            'max_price',
            'min_price',
            'make',
            'model',
            'max_mileage',
            'min_year',
            'keywords',
          ])
            if (args.containsKey(k)) k: args[k],
          if (args.containsKey('vehicle_class')) 'body_style': args['vehicle_class'],
        };
        search.update(changes, applyNow: false);
        await search.apply();
        final s = ref.read(searchProvider);
        final site = CuratedSites.byId(s.siteId)?.name ?? s.siteId;
        if (s.note != null) return {'error': s.note, 'query': s.query.describe(), 'site': site};
        final results = ref
            .read(listingStoreProvider)
            .searchQuery(s.query, limit: (args['limit'] as num?)?.toInt() ?? 5);
        return {
          'query': s.query.describe(),
          'site': site,
          'count': s.lastCount ?? results.length,
          'listings': [for (final l in results) l.toModelJson()],
          if (results.isEmpty)
            'note':
                'The $site page for this search is open and was read; nothing on it matched. '
                'Say so plainly and suggest loosening a filter or trying another site.',
        };
      default:
        throw StateError('no handler for $name');
    }
  }

  BuyerProfile get profile => _pipeline?.profile ?? const BuyerProfile();

  static String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('exceeds available state') || s.contains('context')) {
      return 'The conversation grew past what this model can hold in memory. Start a new conversation to continue.';
    }
    if (e is TimeoutException) return e.message ?? 'The advisor took too long to answer.';
    return 'Something went wrong: $s';
  }
}
