import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

class ThinkingWidget extends StatelessWidget {
  const ThinkingWidget({
    super.key,
    required this.thinking,
    this.isExpanded = false,
    this.onToggle,
  });

  final ThinkingResponse thinking;
  final bool isExpanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onToggle,
            child: Row(
              children: [
                Icon(
                  Icons.psychology,
                  size: 16.0,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8.0),
                Text(
                  'Thinking...',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                if (onToggle != null) ...[
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16.0,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ],
            ),
          ),
          if (isExpanded) ...[
            const SizedBox(height: 8.0),
            Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
                borderRadius: BorderRadius.circular(4.0),
              ),
              child: Text(
                thinking.content,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Widget for accumulated thinking content during streaming
class StreamingThinkingWidget extends StatefulWidget {
  const StreamingThinkingWidget({
    super.key,
    required this.content,
    this.isExpanded = false,
    this.onToggle,
  });

  final String content;
  final bool isExpanded;
  final VoidCallback? onToggle;

  @override
  State<StreamingThinkingWidget> createState() =>
      _StreamingThinkingWidgetState();
}

class _StreamingThinkingWidgetState extends State<StreamingThinkingWidget>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: widget.onToggle,
            child: Row(
              children: [
                AnimatedBuilder(
                  animation: _fadeAnimation,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _fadeAnimation.value,
                      child: Icon(
                        Icons.psychology,
                        size: 16.0,
                        color: theme.colorScheme.primary,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8.0),
                Text(
                  'Thinking...',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8.0),
                SizedBox(
                  width: 12.0,
                  height: 12.0,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.0,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.primary,
                    ),
                  ),
                ),
                const Spacer(),
                if (widget.onToggle != null) ...[
                  Icon(
                    widget.isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16.0,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ],
            ),
          ),
          if (widget.isExpanded && widget.content.isNotEmpty) ...[
            const SizedBox(height: 8.0),
            Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
                borderRadius: BorderRadius.circular(4.0),
              ),
              child: Text(
                widget.content,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
