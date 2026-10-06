import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_service.dart';

enum StageMode { web, cards }

class StageState {
  const StageState({this.mode = StageMode.web, this.cards = const [], this.focus = 0});

  final StageMode mode;

  /// Presented cards, newest first. Only [focus] is shown large; the rest are
  /// chips (TQ62: no stacking).
  final List<ShownComponent> cards;
  final int focus;

  ShownComponent? get focused => cards.isEmpty ? null : cards[focus.clamp(0, cards.length - 1)];

  StageState copyWith({StageMode? mode, List<ShownComponent>? cards, int? focus}) =>
      StageState(mode: mode ?? this.mode, cards: cards ?? this.cards, focus: focus ?? this.focus);
}

final stageProvider = NotifierProvider<StageNotifier, StageState>(StageNotifier.new);

/// The content area above the conversation. It shows either the web pane or
/// the cards the model (or the app) has presented. Presenting a card brings
/// the cards forward; opening a page brings the web forward. The person can
/// flip between them any time (DD principle 5).
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
    );
  }

  void removeWhere(bool Function(ShownComponent) test) =>
      state = state.copyWith(cards: state.cards.where((s) => !test(s)).toList(), focus: 0);

  void focusCard(int i) => state = state.copyWith(focus: i, mode: StageMode.cards);

  void showWeb() => state = state.copyWith(mode: StageMode.web);

  void setMode(StageMode m) => state = state.copyWith(mode: m);

  void markAnswered(ShownComponent c) => state = state.copyWith(
    cards: [
      for (final s in state.cards)
        if (identical(s, c)) s.copyWith(answered: true) else s,
    ],
  );

  void clear() => state = const StageState();
}
