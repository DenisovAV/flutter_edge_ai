import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../advisor/display_agent.dart';
import '../advisor/display_rules.dart';
import 'search_service.dart';

/// The live filters as a card inside the conversation. It is app-owned and
/// bound to the search state, so it can never show a stale filter and the
/// model is never asked to render it. Each tap applies at once; the site row
/// chooses where to look. The display decision picks expanded, summary or
/// hidden; the person's own expand or collapse wins until a filter changes.
class SearchFiltersCard extends ConsumerWidget {
  const SearchFiltersCard({super.key});

  /// Price ceilings as chips: the rungs most used-car shoppers name first.
  static const priceCeilings = [25000, 35000, 50000, 75000];

  /// Mileage ceilings: under 50k reads as "like new", under 100k as "safe".
  static const mileageCeilings = [50000, 100000];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(searchProvider);
    final q = search.query;
    final svc = ref.read(searchProvider.notifier);
    final theme = Theme.of(context);
    final mode = ref.watch(displayProvider).filters;
    return switch (mode) {
      // The key marks the slot, not a visible card, so tests can see that
      // the card is hidden rather than missing.
      FiltersCardMode.hidden => const SizedBox.shrink(key: Key('card-search_filters')),
      FiltersCardMode.summary => Card(
        key: const Key('card-search_filters'),
        child: ListTile(
          key: const Key('filters-summary'),
          dense: true,
          leading: const Icon(Icons.filter_alt_outlined),
          title: Text(
            '${q.describe()} · ${search.siteName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const _SearchStatus(),
          trailing: const Icon(Icons.expand_more),
          onTap: () => svc.setExpanded(true),
        ),
      ),
      FiltersCardMode.expanded => Card(
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
                  const _SearchStatus(),
                ],
              ),
              const SizedBox(height: 6),
              _ChipRow(
                chips: [
                  _FilterChip(
                    key: const Key('body-any'),
                    label: 'Any type',
                    selected: q.bodyStyle == null,
                    onTap: () => svc.update({'body_style': null}),
                  ),
                  for (final b in SearchQuery.bodyStyles)
                    _FilterChip(
                      key: Key('body-$b'),
                      label: SearchQuery.bodyStyleLabels[b]!,
                      selected: q.bodyStyle == b,
                      onTap: () => svc.update({'body_style': q.bodyStyle == b ? null : b}),
                    ),
                ],
              ),
              _ChipRow(
                chips: [
                  _FilterChip(
                    key: const Key('price-any'),
                    label: 'Any price',
                    selected: q.maxPrice == null,
                    onTap: () => svc.update({'max_price': null}),
                  ),
                  for (final p in priceCeilings)
                    _FilterChip(
                      key: Key('price-$p'),
                      label: 'Under \$${p ~/ 1000}k',
                      selected: q.maxPrice == p.toDouble(),
                      onTap: () => svc.update({'max_price': q.maxPrice == p.toDouble() ? null : p}),
                    ),
                ],
              ),
              _ChipRow(
                chips: [
                  _FilterChip(
                    key: const Key('miles-any'),
                    label: 'Any miles',
                    selected: q.maxMileage == null,
                    onTap: () => svc.update({'max_mileage': null}),
                  ),
                  for (final m in mileageCeilings)
                    _FilterChip(
                      key: Key('miles-$m'),
                      label: 'Under ${m ~/ 1000}k mi',
                      selected: q.maxMileage == m,
                      onTap: () => svc.update({'max_mileage': q.maxMileage == m ? null : m}),
                    ),
                ],
              ),
              const Divider(height: 16),
              _ChipRow(
                leading: Text('Look on', style: theme.textTheme.labelMedium),
                chips: [
                  for (final s in CuratedSites.all)
                    _FilterChip(
                      key: Key('site-${s.id}'),
                      label: s.name,
                      selected: search.siteId == s.id,
                      onTap: () => svc.selectSite(s.id),
                    ),
                ],
              ),
              if (search.note case final note?)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    note,
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    };
  }
}

/// "reading…" while a page is being read, then how many listings matched.
class _SearchStatus extends ConsumerWidget {
  const _SearchStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(searchProvider);
    final text = search.applying
        ? 'reading…'
        : switch (search.lastCount) {
            null => '',
            final n => '$n matched',
          };
    return Text(
      text,
      key: const Key('search-status'),
      style: Theme.of(context).textTheme.labelSmall,
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.chips, this.leading});

  final List<Widget> chips;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 2,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [?leading, ...chips],
  );
}

/// One filter chip. A widget rather than a closure so Flutter can skip the
/// chips whose inputs did not change.
class _FilterChip extends StatelessWidget {
  const _FilterChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilterChip(
    label: Text(label),
    selected: selected,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    labelStyle: Theme.of(context).textTheme.labelMedium,
    onSelected: (_) => onTap(),
  );
}
