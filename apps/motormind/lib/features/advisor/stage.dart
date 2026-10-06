import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_service.dart';

/// The content area above the conversation: what the model (or the app) has
/// put on screen while the advisor is docked. Newest first. This is the
/// "composed screen" of the dynamic-design thesis; the chat below is the
/// commentary on it.
final stageProvider = NotifierProvider<StageNotifier, List<ShownComponent>>(StageNotifier.new);

class StageNotifier extends Notifier<List<ShownComponent>> {
  @override
  List<ShownComponent> build() => const [];

  /// Adds a component. A later presentation of the same result replaces the
  /// earlier one (the model re-presenting an auto-shown card with a richer
  /// component, for example).
  void show(ShownComponent c) {
    final id = c.result?.id;
    final kept = id == null ? state : state.where((s) => s.result?.id != id).toList();
    state = [c, ...kept];
  }

  void retireInteractions() => state = [
    for (final s in state)
      if (s.request.component.isInteraction && !s.answered) s.copyWith(answered: true) else s,
  ];

  void clear() => state = const [];
}
