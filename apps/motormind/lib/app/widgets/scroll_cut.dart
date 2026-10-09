import 'package:flutter/material.dart';

/// Wraps a scrollable so a soft edge appears at the bottom while there is
/// more below: the visible "cut" that tells a person the content continues
/// (TQ69). Whether to nudge the scroll as well is a display decision.
class ScrollCut extends StatefulWidget {
  const ScrollCut({super.key, required this.child, required this.controller});

  final Widget child;

  /// The same controller the scrollable inside [child] uses.
  final ScrollController controller;

  @override
  State<ScrollCut> createState() => _ScrollCutState();
}

class _ScrollCutState extends State<ScrollCut> {
  /// Height of the fade at the bottom edge.
  static const _edgeHeight = 28.0;

  /// Slack before "the end" counts as reached, so a one-pixel overshoot does
  /// not flicker the edge.
  static const _endSlack = 8.0;

  bool _more = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didUpdateWidget(ScrollCut old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_check);
      widget.controller.addListener(_check);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!mounted || !widget.controller.hasClients) return;
    final p = widget.controller.position;
    final more = p.maxScrollExtent > 0 && p.pixels < p.maxScrollExtent - _endSlack;
    if (more != _more) setState(() => _more = more);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surface;
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _check();
            return false;
          },
          child: widget.child,
        ),
        if (_more)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _edgeHeight,
            child: IgnorePointer(
              child: DecoratedBox(
                key: const Key('scroll-cut'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [color.withValues(alpha: 0), color],
                  ),
                ),
                child: const Align(
                  alignment: Alignment.bottomCenter,
                  child: Icon(Icons.keyboard_arrow_down, size: 16),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
