import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_panel.dart';
import 'display_agent.dart';
import 'stage.dart';

/// The Motormind surface state machine (ADR 0006 §4). The model may
/// *request* a state through `present`; the person owns the toggle. A pin
/// that holds the state against requests is planned, not built.
final surfaceProvider = NotifierProvider<SurfaceNotifier, SurfaceState>(SurfaceNotifier.new);

class SurfaceNotifier extends Notifier<SurfaceState> {
  @override
  SurfaceState build() => SurfaceState.collapsed;

  /// From the model.
  void request(SurfaceState next) => state = next;

  /// From the person's control.
  void userSet(SurfaceState next) => state = next;

  void cycle() => state = switch (state) {
    SurfaceState.collapsed => SurfaceState.docked,
    SurfaceState.docked => SurfaceState.fullscreen,
    SurfaceState.fullscreen => SurfaceState.collapsed,
  };
}

/// Lays out the stage and the Motormind surface for the current state:
/// a bubble over the stage, a docked split, or fullscreen. The docked split
/// follows the display decision; the keyboard rule is a hard floor.
class AdvisorSurfaceHost extends ConsumerWidget {
  const AdvisorSurfaceHost({super.key, required this.content});

  final Widget content;

  /// Stage flex (of 100) per split. "Half" leans to the stage so a card's
  /// header clears the fold; "typing" keeps a sliver so the thing being
  /// answered stays visible.
  static int stageFlexFor(StageSplit split) => switch (split) {
    StageSplit.typing => 15,
    StageSplit.third => 33,
    StageSplit.half => 55,
    StageSplit.twoThirds => 66,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(surfaceProvider);
    // The display decision picks Web or Cards for the stage; a manual flip
    // wins. Listened here because this host outlives the stage view.
    ref.listen(displayProvider, (_, d) => ref.read(stageProvider.notifier).applyDecision(d.stage));

    return switch (state) {
      SurfaceState.collapsed => Stack(
        children: [
          content,
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              key: const Key('surface-bubble'),
              onPressed: () => ref.read(surfaceProvider.notifier).userSet(SurfaceState.docked),
              icon: const Icon(Icons.chevron_right),
              label: const Text('Motormind'),
            ),
          ),
        ],
      ),
      SurfaceState.docked => _Docked(content: content),
      SurfaceState.fullscreen => const _Panel(key: Key('surface-fullscreen')),
    };
  }
}

class _Docked extends ConsumerStatefulWidget {
  const _Docked({required this.content});

  final Widget content;

  @override
  ConsumerState<_Docked> createState() => _DockedState();
}

class _DockedState extends ConsumerState<_Docked> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The keyboard shows up as a bottom inset; the display decision wants to
  /// know, and the widget tree is where that is known.
  @override
  void didChangeMetrics() {
    final keyboardUp = View.of(context).viewInsets.bottom > 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(keyboardOpenProvider.notifier).set(keyboardUp);
    });
  }

  @override
  Widget build(BuildContext context) {
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final split = keyboardUp ? StageSplit.typing : ref.watch(displayProvider).split;
    final stageFlex = AdvisorSurfaceHost.stageFlexFor(split);
    return Column(
      children: [
        Expanded(
          flex: stageFlex,
          child: ClipRect(child: widget.content),
        ),
        Expanded(
          flex: 100 - stageFlex,
          child: const _Panel(key: Key('surface-docked')),
        ),
      ],
    );
  }
}

/// The conversation panel with its header: the name, the display indicator
/// and the surface toggle.
class _Panel extends ConsumerWidget {
  const _Panel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final decision = ref.watch(displayProvider);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: ChatPanel(
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 16),
                Expanded(child: Text('Motormind', style: theme.textTheme.titleSmall)),
                _DisplayIndicator(decision: decision),
                const _SurfaceToggle(),
              ],
            ),
            if (decision.cue case final cue?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(cue, key: const Key('display-cue'), style: theme.textTheme.labelSmall),
              ),
          ],
        ),
      ),
    );
  }
}

/// The display agent's indicator (the design rule: the person only needs to know the screen may change): a small fixed mark that the
/// screen may change, never a row. The tooltip says who decided and how long
/// it took.
class _DisplayIndicator extends StatelessWidget {
  const _DisplayIndicator({required this.decision});

  final DisplayDecision decision;

  String get _tooltip {
    if (decision.thinking) return 'Motormind is arranging the screen';
    final took = decision.tookMs == null ? '' : ' in ${decision.tookMs} ms';
    return 'Screen arranged by ${decision.by.name}$took';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: _tooltip,
      child: SizedBox(
        key: const Key('display-indicator'),
        width: 12,
        height: 12,
        child: decision.thinking
            ? const CircularProgressIndicator(strokeWidth: 1.5)
            : Icon(
                Icons.circle,
                size: 8,
                color: decision.by == DecidedBy.model
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
      ),
    );
  }
}

/// The signature "</>" control: cycles collapsed, docked, fullscreen.
class _SurfaceToggle extends ConsumerWidget {
  const _SurfaceToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: const Key('surface-toggle'),
    tooltip: 'Expand or collapse Motormind',
    icon: const Icon(Icons.code),
    onPressed: ref.read(surfaceProvider.notifier).cycle,
  );
}
