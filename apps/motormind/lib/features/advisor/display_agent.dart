import 'dart:async';
import 'dart:convert';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/prefs.dart';
import '../../services/advisor_model_service.dart';
import '../../services/log.dart';
import '../chat/chat_service.dart';
import '../search/search_service.dart';
import 'advisor_surface.dart';
import 'display_rules.dart';
import 'stage.dart';

/// Who made the current display decision.
enum DecidedBy {
  /// The rules table.
  rules,

  /// The second model session.
  model,

  /// The model answered but could not be read; the rules' answer stands.
  modelFallback,

  /// The model failed or timed out; the rules' answer stands.
  modelFailed,
}

/// Which agent is in charge of the screen.
enum DisplayAgentMode {
  /// The rules table (the default until the model is measured on a phone).
  rules,

  /// A second session of the loaded model, with the rules as fallback.
  model,
}

/// The stage's share of the screen when docked.
enum StageSplit {
  /// A sliver while typing: the conversation gets the room (the keyboard rule).
  typing,

  /// A third: the page is eye candy until a selection is made.
  third,

  /// Half, leaning to the stage so a card's header clears the fold.
  half,

  /// Two thirds: there are cards to look at.
  twoThirds,
}

/// The display agent's output: a few named decisions over the registry's
/// visibility slots. Everything else about the screen is the allocator's.
class DisplayDecision {
  const DisplayDecision({
    required this.filters,
    required this.notes,
    required this.stage,
    required this.split,
    this.cue,
    this.by = DecidedBy.rules,
    this.tookMs,
    this.thinking = false,
  });

  /// Longest cue the agent may show; one line on a phone.
  static const maxCueLength = 60;

  final FiltersCardMode filters;

  /// Transcript search notes shown or hidden.
  final bool notes;
  final StageMode stage;
  final StageSplit split;

  /// One optional line of orientation (principle 6), at most [maxCueLength].
  final String? cue;
  final DecidedBy by;

  /// How long the model took, when it decided.
  final int? tookMs;

  /// True while the model is being asked; the indicator shows it.
  final bool thinking;

  DisplayDecision copyWith({
    FiltersCardMode? filters,
    bool? notes,
    StageMode? stage,
    StageSplit? split,
    String? cue,
    bool clearCue = false,
    DecidedBy? by,
    int? tookMs,
    bool? thinking,
  }) => DisplayDecision(
    filters: filters ?? this.filters,
    notes: notes ?? this.notes,
    stage: stage ?? this.stage,
    split: split ?? this.split,
    cue: clearCue ? null : (cue ?? this.cue),
    by: by ?? this.by,
    tookMs: tookMs ?? this.tookMs,
    thinking: thinking ?? this.thinking,
  );

  Map<String, Object?> toJson() => {
    'filters': filters.name,
    'notes': notes ? 'shown' : 'hidden',
    'stage': stage.name,
    'split': split.name,
    if (cue != null) 'cue': cue,
  };

  @override
  String toString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is DisplayDecision &&
      other.filters == filters &&
      other.notes == notes &&
      other.stage == stage &&
      other.split == split &&
      other.cue == cue &&
      other.by == by &&
      other.tookMs == tookMs &&
      other.thinking == thinking;

  @override
  int get hashCode => Object.hash(filters, notes, stage, split, cue, by, tookMs, thinking);
}

/// What the display agent sees: screen state plus the last thing the person
/// said (so "show me the website" works without a tool), never the
/// conversation itself.
class ScreenState {
  const ScreenState({
    required this.surface,
    required this.keyboardOpen,
    required this.filtersSet,
    required this.filtersSummary,
    required this.cardCount,
    required this.listingCount,
    required this.stageMode,
    required this.userStageMode,
    required this.userExpandedFilters,
    required this.lastUserText,
    required this.busy,
  });

  /// Characters of the person's last message the agent sees.
  static const lastUserTextLength = 80;

  final SurfaceState surface;
  final bool keyboardOpen;
  final bool filtersSet;
  final String filtersSummary;
  final int cardCount;
  final int listingCount;
  final StageMode stageMode;

  /// The person flipped the stage by hand this search; that wins.
  final bool userStageMode;
  final bool? userExpandedFilters;
  final String lastUserText;

  /// True while a conversation turn is running; the model agent waits.
  final bool busy;

  /// One line for the model.
  String describe() {
    final text = lastUserText.length > lastUserTextLength
        ? lastUserText.substring(0, lastUserTextLength)
        : lastUserText;
    return 'surface=${surface.name}; keyboard=${keyboardOpen ? 'open' : 'closed'}; '
        'filters=${filtersSet ? filtersSummary : 'none'}; cards=$cardCount; '
        'listings=$listingCount; stage=${stageMode.name}; last_user_text="$text"';
  }
}

/// Rules first (the table in [DisplayRules]), a model second. Both produce
/// the same decision shape, so they can be compared on the same inputs.
abstract class DisplayAgent {
  Future<DisplayDecision> decide(ScreenState s, DisplayDecision defaults);
}

/// The rules table, applied synchronously.
class RulesDisplayAgent implements DisplayAgent {
  const RulesDisplayAgent();

  /// The decision the rules make for [s].
  static DisplayDecision apply(ScreenState s) {
    final c = DisplayContext(
      surface: s.surface,
      filtersSet: s.filtersSet,
      keyboardOpen: s.keyboardOpen,
      userExpandedFilters: s.userExpandedFilters,
    );
    // Cards whenever there is a card to show; the web page when there is
    // none, or when the person or the app asked for it.
    final stage = s.userStageMode
        ? s.stageMode
        : (s.cardCount > 0 ? StageMode.cards : StageMode.web);
    final StageSplit split;
    if (s.keyboardOpen) {
      split = StageSplit.typing;
    } else if (s.listingCount > 0 && stage == StageMode.cards) {
      split = StageSplit.twoThirds;
    } else {
      split = StageSplit.half;
    }
    return DisplayDecision(
      filters: DisplayRules.filtersCard(c),
      notes: DisplayRules.showSearchNotes(c),
      stage: stage,
      split: split,
    );
  }

  @override
  Future<DisplayDecision> decide(ScreenState s, DisplayDecision defaults) async => apply(s);
}

/// The display prompt, an asset like the other prompts so it can be tuned
/// without a rebuild.
final displayPromptProvider = FutureProvider<String>(
  (ref) => rootBundle.loadString('assets/prompts/display.md'),
);

/// A second session of the loaded model, opened per decision with a short
/// prompt and closed after. Generation is serialized with the conversation
/// by the engine, and on the FFI engine a session switch replays the other
/// session's history, so this runs only while the conversation is idle and
/// the cost is logged every time (TQ59: measure prompt size per turn).
class ModelDisplayAgent implements DisplayAgent {
  ModelDisplayAgent(this.model, this.systemInstruction);

  /// Enough for one small JSON object.
  static const maxOutputTokens = 80;

  /// Generous on purpose: the emulator under software GL needs most of it;
  /// a phone should answer in a second or two, and the time is logged.
  static const decisionTimeout = Duration(seconds: 60);

  final InferenceModel model;
  final String systemInstruction;

  @override
  Future<DisplayDecision> decide(ScreenState s, DisplayDecision defaults) async {
    final sw = Stopwatch()..start();
    InferenceModelSession? session;
    try {
      session = await model.openSession(
        temperature: 0.1,
        systemInstruction: systemInstruction,
        maxOutputTokens: maxOutputTokens,
      );
      await session.addQueryChunk(
        Message.text(text: 'Screen: ${s.describe()}\nDefault: ${defaults.toJson()}', isUser: true),
      );
      final raw = await session.getResponse().timeout(decisionTimeout);
      return parse(raw, defaults).copyWith(tookMs: sw.elapsedMilliseconds);
    } finally {
      await session?.close();
    }
  }

  /// Reads one JSON object out of [raw]; anything unreadable keeps the
  /// corresponding default. Visible for tests.
  static DisplayDecision parse(String raw, DisplayDecision d) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return d.copyWith(by: DecidedBy.modelFallback);
    final Map<String, Object?> m;
    try {
      m = (jsonDecode(raw.substring(start, end + 1)) as Map).cast<String, Object?>();
    } on FormatException {
      return d.copyWith(by: DecidedBy.modelFallback);
    }
    final cue = m['cue']?.toString();
    return DisplayDecision(
      filters: FiltersCardMode.values.asNameMap()[m['filters']?.toString()] ?? d.filters,
      notes: m['notes'] == null ? d.notes : m['notes'].toString() == 'shown',
      stage: StageMode.values.asNameMap()[m['stage']?.toString()] ?? d.stage,
      split: StageSplit.values.asNameMap()[m['split']?.toString()] ?? d.split,
      cue: cue == null || cue == 'null' || cue.isEmpty
          ? null
          : (cue.length > DisplayDecision.maxCueLength
                ? cue.substring(0, DisplayDecision.maxCueLength)
                : cue),
      by: DecidedBy.model,
    );
  }
}

/// Which agent is in charge. Persisted; the Models screen offers the switch.
/// One model, two sessions: the second gets the screen state and returns a
/// few layout decisions; the rules table is its fallback and its benchmark.
/// Off by default until the replay cost is measured on a phone.
final displayAgentModeProvider = NotifierProvider<DisplayAgentModeNotifier, DisplayAgentMode>(
  DisplayAgentModeNotifier.new,
);

class DisplayAgentModeNotifier extends Notifier<DisplayAgentMode> {
  static const _key = 'display.agent';

  @override
  DisplayAgentMode build() =>
      DisplayAgentMode.values.asNameMap()[ref.watch(sharedPreferencesProvider).getString(_key)] ??
      DisplayAgentMode.rules;

  Future<void> set(DisplayAgentMode mode) async {
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(_key, mode.name);
  }
}

/// Whether the keyboard is up, reported by the surface host (the widget tree
/// knows; providers do not).
final keyboardOpenProvider = NotifierProvider<KeyboardOpenNotifier, bool>(KeyboardOpenNotifier.new);

class KeyboardOpenNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool v) {
    if (v != state) state = v;
  }
}

/// The current decision. Rules answer at once on every change; when the model
/// is in charge it is asked after a short pause, while the conversation is
/// idle, and its answer replaces the rules' until the next change. The
/// person's manual choices are inputs, and they win.
final displayProvider = NotifierProvider<DisplayController, DisplayDecision>(DisplayController.new);

class DisplayController extends Notifier<DisplayDecision> {
  /// A screen change settles for this long before the model is asked, so a
  /// run of taps costs one decision.
  static const decideDebounce = Duration(milliseconds: 800);

  Timer? _debounce;
  int _generation = 0;

  @override
  DisplayDecision build() {
    ref.onDispose(() => _debounce?.cancel());
    final s = _screen();
    final rules = RulesDisplayAgent.apply(s);
    // The model agent runs only once the conversation has started and is
    // idle: on the FFI engine a session switch replays the other session's
    // history, and running it before the first turn doubled that turn's
    // time on the emulator (experiment log, 2026-10-08). The mode is
    // watched, so flipping the switch takes effect at once.
    final mode = ref.watch(displayAgentModeProvider);
    if (mode == DisplayAgentMode.model && !s.busy && s.lastUserText.isNotEmpty) {
      _askModel(s, rules);
    }
    return rules;
  }

  ScreenState _screen() {
    final search = ref.watch(searchProvider);
    final stage = ref.watch(stageProvider);
    final chat = ref.watch(chatServiceProvider);
    final listings = stage.cards
        .where((c) => c.request.component.id == 'vehicle_card')
        .fold<int>(0, (n, c) => n + ((c.result?.result?['listings'] as List?)?.length ?? 0));
    return ScreenState(
      surface: ref.watch(surfaceProvider),
      keyboardOpen: ref.watch(keyboardOpenProvider),
      filtersSet: !search.query.isEmpty,
      filtersSummary: search.query.describe(),
      cardCount: stage.cards.length,
      listingCount: listings,
      stageMode: stage.mode,
      userStageMode: stage.userSet,
      userExpandedFilters: search.userExpanded,
      lastUserText: chat.lastUserText,
      busy: chat.busy,
    );
  }

  /// Asks the model after [decideDebounce]; a newer screen change cancels a
  /// stale answer. The timer fires after build, so build stays pure.
  void _askModel(ScreenState s, DisplayDecision defaults) {
    final model = ref.read(advisorModelServiceProvider.notifier).loadedModel;
    if (model == null) return;
    final gen = ++_generation;
    _debounce?.cancel();
    _debounce = Timer(decideDebounce, () async {
      final prompt = await ref.read(displayPromptProvider.future);
      if (gen != _generation) return;
      state = state.copyWith(thinking: true);
      try {
        final d = await ModelDisplayAgent(model, prompt).decide(s, defaults);
        if (gen != _generation) return; // the screen moved on
        logDev('display model=${d.toJson()} rules=${defaults.toJson()} took=${d.tookMs}ms');
        state = d;
      } on Exception catch (e) {
        logDev('display model failed: $e');
        if (gen == _generation) {
          state = state.copyWith(by: DecidedBy.modelFailed, thinking: false, clearCue: true);
        }
      }
    });
  }
}
