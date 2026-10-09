import 'dart:async';
import 'dart:convert';

import 'package:advisor_core/advisor_core.dart';
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

/// The display agent's output: a few named decisions over the registry's
/// visibility slots. Everything else about the screen is the allocator's.
class DisplayDecision {
  const DisplayDecision({
    required this.filters,
    required this.notes,
    required this.stage,
    required this.split,
    this.cue,
    this.by = 'rules',
    this.tookMs,
  });

  final FiltersCardMode filters;

  /// Transcript search notes shown or hidden.
  final bool notes;
  final StageMode stage;

  /// The stage's share of the screen when docked.
  final StageSplit split;

  /// One optional line of orientation (principle 6), at most 60 characters.
  final String? cue;

  /// Who decided: `rules` or `model`.
  final String by;
  final int? tookMs;

  DisplayDecision copyWith({
    FiltersCardMode? filters,
    bool? notes,
    StageMode? stage,
    StageSplit? split,
    String? cue,
    String? by,
    int? tookMs,
  }) => DisplayDecision(
    filters: filters ?? this.filters,
    notes: notes ?? this.notes,
    stage: stage ?? this.stage,
    split: split ?? this.split,
    cue: cue ?? this.cue,
    by: by ?? this.by,
    tookMs: tookMs ?? this.tookMs,
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
}

enum StageSplit { third, half, twoThirds }

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

  final SurfaceState surface;
  final bool keyboardOpen;
  final bool filtersSet;
  final String filtersSummary;
  final int cardCount;
  final int listingCount;
  final StageMode stageMode;

  /// The person flipped the stage by hand this search; that wins (DD-R13).
  final bool userStageMode;
  final bool? userExpandedFilters;
  final String lastUserText;
  final bool busy;

  String describe() =>
      'surface=${surface.name}; keyboard=${keyboardOpen ? 'open' : 'closed'}; '
      'filters=${filtersSet ? filtersSummary : 'none'}; cards=$cardCount; listings=$listingCount; '
      'stage=${stageMode.name}; last_user_text="${lastUserText.length > 80 ? lastUserText.substring(0, 80) : lastUserText}"';
}

/// Rules first (the table in DisplayRules), a model second. Both produce the
/// same decision shape, so they can be compared on the same inputs (DD-R21).
abstract class DisplayAgent {
  Future<DisplayDecision> decide(ScreenState s, DisplayDecision defaults);
}

class RulesDisplayAgent implements DisplayAgent {
  const RulesDisplayAgent();

  static DisplayDecision apply(ScreenState s) {
    final c = DisplayContext(
      surface: s.surface,
      filtersSet: s.filtersSet,
      keyboardOpen: s.keyboardOpen,
      userExpandedFilters: s.userExpandedFilters,
    );
    // Cards whenever there is a card to show (DD-R24); the web page when
    // there is none, or when the person or the app asked for it.
    final stage = s.userStageMode
        ? s.stageMode
        : (s.cardCount > 0 ? StageMode.cards : StageMode.web);
    return DisplayDecision(
      filters: DisplayRules.filtersCard(c),
      notes: DisplayRules.showSearchNotes(c),
      stage: stage,
      // TQ66: the web page is eye candy until a selection is made; once there
      // are cards they get the room.
      split: s.keyboardOpen
          ? StageSplit.third
          : (s.listingCount > 0 && stage == StageMode.cards
                ? StageSplit.twoThirds
                : StageSplit.half),
    );
  }

  @override
  Future<DisplayDecision> decide(ScreenState s, DisplayDecision defaults) async => apply(s);
}

/// A second session of the loaded model, opened per decision with a tiny
/// prompt and closed after. Generation is serialized with the interaction
/// session by the engine, and on the FFI engine a session switch replays the
/// other session's history, so this runs only while the conversation is idle
/// and the cost is logged every time (TQ59: "measure the thing we care
/// about, prompt size per turn").
class ModelDisplayAgent implements DisplayAgent {
  ModelDisplayAgent(this.model);

  final InferenceModel model;

  static const systemInstruction =
      'You arrange a phone screen for a car-shopping assistant. You get the screen state and '
      'must answer with one JSON object and nothing else, keys: '
      'filters (expanded|summary|hidden), notes (shown|hidden), stage (web|cards), '
      'split (third|half|twoThirds), cue (a short orientation line or null). '
      'Rules: while the keyboard is open hide the filters and give the conversation room; '
      'when listings exist show cards unless the person asked for the website; '
      'collapse filters to a summary once something is set unless the surface is fullscreen; '
      'show notes only in fullscreen; a cue only when the person returns or something changed.';

  @override
  Future<DisplayDecision> decide(ScreenState s, DisplayDecision defaults) async {
    final sw = Stopwatch()..start();
    InferenceModelSession? session;
    try {
      session = await model.openSession(
        temperature: 0.1,
        systemInstruction: systemInstruction,
        maxOutputTokens: 80,
      );
      await session.addQueryChunk(
        Message.text(text: 'Screen: ${s.describe()}\nDefault: ${defaults.toJson()}', isUser: true),
      );
      // Generous on purpose: the emulator under software GL needs most of this; a
      // phone should answer in a second or two, and the time is logged.
      final raw = await session.getResponse().timeout(const Duration(seconds: 60));
      final parsed = _parse(raw, defaults);
      return parsed.copyWith(by: 'model', tookMs: sw.elapsedMilliseconds);
    } finally {
      await session?.close();
    }
  }

  static DisplayDecision _parse(String raw, DisplayDecision d) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return d.copyWith(by: 'model-fallback');
    Map<String, Object?> m;
    try {
      m = (jsonDecode(raw.substring(start, end + 1)) as Map).cast<String, Object?>();
    } catch (_) {
      return d.copyWith(by: 'model-fallback');
    }
    T pick<T extends Enum>(List<T> values, Object? v, T fallback) =>
        values.where((e) => e.name == v?.toString()).firstOrNull ?? fallback;
    final cue = m['cue']?.toString();
    return DisplayDecision(
      filters: pick(FiltersCardMode.values, m['filters'], d.filters),
      notes: m['notes'] == null ? d.notes : m['notes'].toString() == 'shown',
      stage: pick(StageMode.values, m['stage'], d.stage),
      split: pick(StageSplit.values, m['split'], d.split),
      cue: cue == null || cue == 'null' || cue.isEmpty
          ? null
          : (cue.length > 60 ? cue.substring(0, 60) : cue),
    );
  }
}

/// Which agent is in charge. Persisted; the Models screen offers the switch.
final displayAgentModeProvider = NotifierProvider<DisplayAgentModeNotifier, String>(
  DisplayAgentModeNotifier.new,
);

class DisplayAgentModeNotifier extends Notifier<String> {
  static const key = 'display.agent';

  @override
  String build() => ref.watch(sharedPreferencesProvider).getString(key) ?? 'rules';

  Future<void> set(String mode) async {
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(key, mode);
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
  Timer? _debounce;
  int _generation = 0;
  bool thinking = false;

  @override
  DisplayDecision build() {
    ref.onDispose(() => _debounce?.cancel());
    final s = _screen();
    final rules = RulesDisplayAgent.apply(s);
    // The model agent runs only once the conversation has started and is
    // idle: on the FFI engine a session switch replays the other session's
    // history, and running it before the first turn made that turn twice as
    // slow on the emulator (experiment log, 2026-10-08).
    if (ref.read(displayAgentModeProvider) == 'model' && !s.busy && s.lastUserText.isNotEmpty) {
      _askModel(s, rules);
    }
    return rules;
  }

  ScreenState _screen() {
    final search = ref.watch(searchProvider);
    final stage = ref.watch(stageProvider);
    final chat = ref.watch(chatServiceProvider);
    final listings = stage.cards.where((c) => c.request.component.id == 'vehicle_card').fold<int>(
      0,
      (n, c) {
        final r = c.result;
        return n + ((r?.result?['listings'] as List?)?.length ?? 0);
      },
    );
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

  void _askModel(ScreenState s, DisplayDecision defaults) {
    final model = ref.read(advisorModelServiceProvider.notifier).loadedModel;
    if (model == null) return;
    final gen = ++_generation;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () async {
      thinking = true;
      state = state.copyWith(); // repaint the indicator
      try {
        final d = await ModelDisplayAgent(model).decide(s, defaults);
        if (gen != _generation) return; // the screen moved on
        logDev('display model=${d.toJson()} rules=${defaults.toJson()} took=${d.tookMs}ms');
        state = d;
      } catch (e) {
        logDev('display model failed: $e');
      } finally {
        thinking = false;
        if (gen == _generation) state = state.copyWith();
      }
    });
  }
}
