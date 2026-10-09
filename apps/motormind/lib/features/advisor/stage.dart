import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_state.dart';

/// What the stage shows: the web pane or the presented cards.
enum StageMode {
  /// The curated site, the source of what the cards show.
  web,

  /// The cards the model or the app presented; the primary surface.
  cards,
}

/// The content area above the conversation.
class StageState {
  const StageState({
    this.mode = StageMode.web,
    this.cards = const [],
    this.focus = 0,
    this.userSet = false,
  });

  final StageMode mode;

  /// True when the person flipped Web/Cards by hand (or the app asked for
  /// the page to be seen); the display decision respects it until the next
  /// presented card.
  final bool userSet;

  /// Presented cards, newest first. Only [focus] is shown large; the rest are
  /// chips (no stacking: one card large at a time).
  final List<ShownComponent> cards;

  /// Index into [cards] of the one shown large; clamped on read.
  final int focus;

  ShownComponent? get focused => cards.isEmpty ? null : cards[focus.clamp(0, cards.length - 1)];

  StageState copyWith({StageMode? mode, List<ShownComponent>? cards, int? focus, bool? userSet}) =>
      StageState(
        mode: mode ?? this.mode,
        cards: cards ?? this.cards,
        focus: focus ?? this.focus,
        userSet: userSet ?? this.userSet,
      );
}

/// The stage: either the web pane or the cards the model (or the app) has
/// presented. Presenting a card brings the cards forward; opening a page
/// brings the web forward; the person can flip between them any time.
final stageProvider = NotifierProvider<StageNotifier, StageState>(StageNotifier.new);

class StageNotifier extends Notifier<StageState> {
  @override
  StageState build() => const StageState();

  /// Adds a component at the front. [bringForward] flips to Cards; the live
  /// search leaves the web page in view and only badges the Cards tab.
  void show(ShownComponent c, {bool bringForward = true}) {
    final id = c.result?.id;
    final kept = id == null ? state.cards : state.cards.where((s) => s.result?.id != id).toList();
    state = state.copyWith(
      mode: bringForward ? StageMode.cards : state.mode,
      cards: [c, ...kept],
      focus: 0,
      userSet: false,
    );
  }

  /// Drops the cards matching [test] and focuses the newest remaining one.
  void removeWhere(bool Function(ShownComponent) test) =>
      state = state.copyWith(cards: state.cards.where((s) => !test(s)).toList(), focus: 0);

  /// Shows card [i] large (from the chip strip).
  void focusCard(int i) {
    assert(i >= 0 && i < state.cards.length, 'card index $i out of range');
    state = state.copyWith(focus: i.clamp(0, state.cards.length - 1), mode: StageMode.cards);
  }

  /// The page needs to be seen (a read in progress, a human check, an
  /// "open on site" tap): this holds until the next presented card.
  void showWeb() => state = state.copyWith(mode: StageMode.web, userSet: true);

  /// From the person's own Web/Cards control.
  void setMode(StageMode m) => state = state.copyWith(mode: m, userSet: true);

  /// From the display decision; never overrides a manual flip.
  void applyDecision(StageMode m) {
    if (!state.userSet && state.mode != m && (m == StageMode.web || state.cards.isNotEmpty)) {
      state = state.copyWith(mode: m);
    }
  }
}
