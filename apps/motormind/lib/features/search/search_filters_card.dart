import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../advisor/advisor_surface.dart';
import '../advisor/display_rules.dart';
import 'search_service.dart';

/// The standard questions, as a live card inside the conversation. It is bound
/// to the search state, so it always shows the current filters and never
/// retires. Each tap applies at once; the site chips choose where to look.
class SearchFiltersCard extends ConsumerWidget {
  const SearchFiltersCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(searchProvider);
    final q = search.query;
    final svc = ref.read(searchProvider.notifier);
    final theme = Theme.of(context);
    final mode = DisplayRules.filtersCard(
      DisplayContext(
        surface: ref.watch(surfaceProvider),
        filtersSet: !q.isEmpty,
        keyboardOpen: MediaQuery.viewInsetsOf(context).bottom > 0,
        userExpandedFilters: search.userExpanded,
      ),
    );
    if (mode == FiltersCardMode.hidden)
      return const SizedBox.shrink(key: Key('card-search_filters'));
    if (mode == FiltersCardMode.summary) {
      return Card(
        key: const Key('card-search_filters'),
        child: ListTile(
          key: const Key('filters-summary'),
          dense: true,
          leading: const Icon(Icons.filter_alt_outlined),
          title: Text(
            '${q.describe()} · ${CuratedSites.byId(search.siteId)?.name ?? search.siteId}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            search.applying
                ? 'reading…'
                : search.lastCount == null
                ? ''
                : '${search.lastCount} read',
            key: const Key('search-status'),
          ),
          trailing: const Icon(Icons.expand_more),
          onTap: () => svc.setExpanded(true),
        ),
      );
    }

    Widget chip(String label, bool selected, VoidCallback onTap, {Key? key}) => FilterChip(
      key: key,
      label: Text(label),
      selected: selected,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelStyle: theme.textTheme.labelMedium,
      onSelected: (_) => onTap(),
    );

    return Card(
      key: const Key('card-search_filters'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('What are we looking for?', style: theme.textTheme.titleMedium),
                ),
                if (!q.isEmpty)
                  IconButton(
                    key: const Key('filters-collapse'),
                    tooltip: 'Collapse',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.expand_less),
                    onPressed: () => svc.setExpanded(false),
                  ),
                Text(
                  search.applying
                      ? 'reading…'
                      : search.lastCount == null
                      ? ''
                      : '${search.lastCount} read',
                  key: const Key('search-status'),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                chip(
                  'Any type',
                  q.bodyStyle == null,
                  () => svc.update({'body_style': null}),
                  key: const Key('body-any'),
                ),
                for (final b in SearchQuery.bodyStyles)
                  chip(
                    SearchQuery.bodyStyleLabels[b]!,
                    q.bodyStyle == b,
                    () => svc.update({'body_style': q.bodyStyle == b ? null : b}),
                    key: Key('body-$b'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                chip(
                  'Any price',
                  q.maxPrice == null,
                  () => svc.update({'max_price': null}),
                  key: const Key('price-any'),
                ),
                for (final p in const [25000, 35000, 50000, 75000])
                  chip(
                    'Under \$${p ~/ 1000}k',
                    q.maxPrice == p.toDouble(),
                    () => svc.update({'max_price': q.maxPrice == p.toDouble() ? null : p}),
                    key: Key('price-$p'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                chip('Any miles', q.maxMileage == null, () => svc.update({'max_mileage': null})),
                for (final m in const [50000, 100000])
                  chip(
                    'Under ${m ~/ 1000}k mi',
                    q.maxMileage == m,
                    () => svc.update({'max_mileage': q.maxMileage == m ? null : m}),
                  ),
              ],
            ),
            const Divider(height: 16),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Look on', style: theme.textTheme.labelMedium),
                ),
                for (final s in CuratedSites.all)
                  chip(
                    s.name,
                    search.siteId == s.id,
                    () => svc.selectSite(s.id),
                    key: Key('site-${s.id}'),
                  ),
              ],
            ),
            if (search.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  search.note!,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
