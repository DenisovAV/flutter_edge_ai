import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_panel.dart';
import 'display_agent.dart';
import 'stage.dart';

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
    // The display decision picks Web or Cards for the stage; a manual flip
    // wins (DD-R13). Listened here because this host outlives the stage.
    ref.listen(displayProvider, (_, d) => ref.read(stageProvider.notifier).applyDecision(d.stage));
    final toggle = IconButton(
      key: const Key('surface-toggle'),
      tooltip: 'Expand or collapse Motormind',
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
              icon: const Icon(Icons.chevron_right),
              label: const Text('Motormind'),
            ),
          ),
        ],
      ),
      // Keyboard rule (DD-R7): while typing, the conversation gets the space and
      // the content shrinks to a strip, so the thing being answered stays visible.
      SurfaceState.docked => Builder(
        builder: (context) {
          final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => ref.read(keyboardOpenProvider.notifier).set(keyboardUp),
          );
          // The stage's share comes from the display decision (rules or the
          // model); the keyboard rule (DD-R7) is a hard floor.
          final split = ref.watch(displayProvider).split;
          final stageFlex = keyboardUp
              ? 15
              : switch (split) {
                  StageSplit.third => 33,
                  StageSplit.half => 55,
                  StageSplit.twoThirds => 66,
                };
          return Column(
            children: [
              Expanded(
                flex: stageFlex,
                child: ClipRect(child: content),
              ),
              Expanded(
                flex: 100 - stageFlex,
                child: _AdvisorPanel(toggle: toggle, label: 'Motormind (docked)'),
              ),
            ],
          );
        },
      ),
      SurfaceState.fullscreen => _AdvisorPanel(toggle: toggle, label: 'Motormind (fullscreen)'),
    };
  }
}

class _AdvisorPanel extends ConsumerWidget {
  const _AdvisorPanel({required this.toggle, required this.label});

  final Widget toggle;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final decision = ref.watch(displayProvider);
    final thinking = ref.read(displayProvider.notifier).thinking;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: ChatPanel(
        header: Row(
          children: [
            const SizedBox(width: 16),
            Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
            // The display agent's indicator (principle 13): a small fixed
            // mark that the screen may change, never a row.
            Tooltip(
              message: thinking
                  ? 'Motormind is arranging the screen'
                  : 'Screen arranged by ${decision.by}'
                        '${decision.tookMs == null ? '' : ' in ${decision.tookMs} ms'}',
              child: SizedBox(
                key: const Key('display-indicator'),
                width: 12,
                height: 12,
                child: thinking
                    ? const CircularProgressIndicator(strokeWidth: 1.5)
                    : Icon(
                        Icons.circle,
                        size: 8,
                        color: decision.by.startsWith('model')
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
              ),
            ),
            toggle,
          ],
        ),
      ),
    );
  }
}
