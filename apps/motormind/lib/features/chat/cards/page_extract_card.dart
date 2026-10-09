import 'package:flutter/material.dart';

import '../chat_state.dart';
import 'formatting.dart';

/// What `read_page` pulled from the page the person has open: the title and
/// address, the figures found by pattern (prices, mileage, year) as chips,
/// and either the listings read or the first lines of text.
class PageExtractCard extends StatelessWidget {
  const PageExtractCard({super.key, required this.shown});

  final ShownComponent shown;

  /// How much page text to show before an ellipsis.
  static const _textPreviewLength = 400;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = shown.result?.result ?? const {};
    final facts = (r['facts'] as Map?)?.cast<String, Object?>() ?? const {};
    final listings = (r['listings'] as List?)?.cast<Map>() ?? const [];
    final text = r['text']?.toString() ?? '';
    final prices = (facts['prices'] as List?) ?? const [];
    return Card(
      key: const Key('card-page_extract'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${r['title'] ?? 'Page'}',
              style: theme.textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${r['url'] ?? ''}',
              style: theme.textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            if (facts.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final p in prices.take(3))
                    Chip(label: Text(money(p, cents: false)), visualDensity: VisualDensity.compact),
                  if (facts['mileage'] != null)
                    Chip(
                      label: Text('${thousands(facts['mileage'])} mi'),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (facts['year'] != null)
                    Chip(label: Text('${facts['year']}'), visualDensity: VisualDensity.compact),
                ],
              ),
            if (listings.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('${listings.length} listings read', style: theme.textTheme.labelLarge),
              for (final l in listings.take(5))
                Text(
                  '• ${l['title']}${l['price'] != null ? ' · ${money(l['price'], cents: false)}' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
            ] else if (text.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                text.length > _textPreviewLength
                    ? '${text.substring(0, _textPreviewLength)}…'
                    : text,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
