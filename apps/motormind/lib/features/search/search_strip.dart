import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_service.dart';
import 'search_service.dart';

/// The standard questions every listing site asks, as one live strip over the
/// web pane. Every tap applies at once; "Describe it" goes to the advisor,
/// which may set several filters from one sentence.
class SearchStrip extends ConsumerStatefulWidget {
  const SearchStrip({super.key});

  @override
  ConsumerState<SearchStrip> createState() => _SearchStripState();
}

class _SearchStripState extends ConsumerState<SearchStrip> {
  final _describe = TextEditingController();

  @override
  void dispose() {
    _describe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(searchProvider);
    final q = search.query;
    final theme = Theme.of(context);
    final svc = ref.read(searchProvider.notifier);

    Widget chip(String label, bool selected, VoidCallback onTap, {Key? key}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        key: key,
        label: Text(label),
        selected: selected,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => onTap(),
      ),
    );

    return Column(
      key: const Key('search-strip'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              chip('Any miles', q.maxMileage == null, () => svc.update({'max_mileage': null})),
              for (final m in const [50000, 100000])
                chip(
                  'Under ${m ~/ 1000}k mi',
                  q.maxMileage == m,
                  () => svc.update({'max_mileage': q.maxMileage == m ? null : m}),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('describe-field'),
                  controller: _describe,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    hintText: 'Describe it: "sports car under 40k", "Toyota, low miles"…',
                    hintStyle: theme.textTheme.bodySmall,
                  ),
                  onSubmitted: (text) {
                    if (text.trim().isEmpty) return;
                    _describe.clear();
                    // Obvious filters apply at once; the sentence goes to the advisor
                    // for anything the inference missed and for commentary.
                    svc.updateFromText(text);
                    ref.read(chatServiceProvider.notifier).send(text);
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: Text(
                  search.applying
                      ? 'Reading…'
                      : search.lastCount == null
                      ? q.describe()
                      : '${search.lastCount} read · ${q.describe()}',
                  key: const Key('search-status'),
                  style: theme.textTheme.labelSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        if (search.note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Text(
              search.note!,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}
