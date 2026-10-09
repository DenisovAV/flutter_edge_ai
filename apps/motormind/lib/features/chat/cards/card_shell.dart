import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

/// The frame every finance card shares: a title, the rows, the assumptions
/// the calculation leaned on (collapsed), and the estimates-only line that no
/// card may drop (DD-R19).
class CardShell extends StatelessWidget {
  const CardShell({
    super.key,
    required this.id,
    required this.title,
    required this.children,
    this.assumptions = const [],
  });

  /// The registry component id; becomes the widget key tests look for.
  final String id;
  final String title;
  final List<Widget> children;
  final List<Map<String, Object?>> assumptions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: Key('card-$id'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
            if (assumptions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    'Assumptions (${assumptions.length})',
                    style: theme.textTheme.labelLarge,
                  ),
                  children: [
                    for (final a in assumptions)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${a['description']}'),
                        subtitle: Text('${a['value']} · ${a['source']} · as of ${a['asOf']}'),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(Disclosures.estimatesOnly.short, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

/// One label-and-value line in a finance card. [valueKey] names the output
/// field so tests can find the value; [emphasis] is the model's highlight.
class ValueRow extends StatelessWidget {
  const ValueRow(
    this.label,
    this.value, {
    super.key,
    this.valueKey,
    this.emphasis = false,
    this.color,
  });

  final String label;
  final String value;
  final String? valueKey;
  final bool emphasis;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            key: valueKey == null ? null : Key('out-$valueKey'),
            style: emphasis
                ? theme.textTheme.titleMedium?.copyWith(
                    color: color ?? theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  )
                : theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// A small heading between groups of rows ("What you pay", "The loan").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );
}
