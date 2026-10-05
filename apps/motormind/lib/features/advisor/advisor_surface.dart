import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_panel.dart';

/// The advisor surface state machine (VA-2.1, ADR 0006 §4).
///
/// The model may *request* a state through `present`; the user owns the
/// toggle and can pin. While pinned, requests update content but not state.
final surfaceProvider = NotifierProvider<SurfaceNotifier, SurfaceState>(SurfaceNotifier.new);

class SurfaceNotifier extends Notifier<SurfaceState> {
  bool pinned = false;

  @override
  SurfaceState build() => SurfaceState.collapsed;

  /// From the model.
  void request(SurfaceState next) {
    if (!pinned) state = next;
  }

  /// From the user's toggle control.
  void userSet(SurfaceState next) => state = next;

  void cycle() => state = switch (state) {
    SurfaceState.collapsed => SurfaceState.docked,
    SurfaceState.docked => SurfaceState.fullscreen,
    SurfaceState.fullscreen => SurfaceState.collapsed,
  };
}

/// Lays out the content area and the advisor surface for the current state.
/// Visual design is deliberately minimal until the components exist.
class AdvisorSurfaceHost extends ConsumerWidget {
  const AdvisorSurfaceHost({super.key, required this.content});

  final Widget content;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(surfaceProvider);
    final notifier = ref.read(surfaceProvider.notifier);
    final toggle = IconButton(
      key: const Key('surface-toggle'),
      tooltip: 'Expand or collapse the advisor',
      icon: const Icon(Icons.code),
      onPressed: notifier.cycle,
    );

    return switch (state) {
      SurfaceState.collapsed => Stack(
        children: [
          content,
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              key: const Key('surface-bubble'),
              onPressed: () => notifier.userSet(SurfaceState.docked),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Advisor'),
            ),
          ),
        ],
      ),
      SurfaceState.docked => Column(
        children: [
          Expanded(flex: 55, child: content),
          Expanded(
            flex: 45,
            child: _AdvisorPanel(toggle: toggle, label: 'Advisor (docked)'),
          ),
        ],
      ),
      SurfaceState.fullscreen => _AdvisorPanel(toggle: toggle, label: 'Advisor (fullscreen)'),
    };
  }
}

class _AdvisorPanel extends StatelessWidget {
  const _AdvisorPanel({required this.toggle, required this.label});

  final Widget toggle;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: ChatPanel(
        header: Row(
          children: [
            const SizedBox(width: 16),
            Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
            toggle,
          ],
        ),
      ),
    );
  }
}
