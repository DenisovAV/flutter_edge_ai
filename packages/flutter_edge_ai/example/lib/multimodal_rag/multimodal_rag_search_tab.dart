part of 'multimodal_rag_widgets.dart';

// ── Search ──────────────────────────────────────────────────────────────────

class SearchTab extends StatelessWidget {
  const SearchTab({
    super.key,
    required this.vm,
    required this.controller,
    required this.onSearch,
  });

  final MultimodalRagViewModel vm;
  final TextEditingController controller;
  final void Function(String text) onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = vm.results;
    final query = vm.resultsFor;
    return ListView(
      key: const Key('multimodal-rag-search'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _ErrorBanner(vm: vm),
        SearchBar(
          key: const Key('multimodal-rag-search-field'),
          controller: controller,
          hintText: 'Search notes, photos and memos',
          leading: const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(Icons.search),
          ),
          trailing: [
            if (vm.searching)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                key: const Key('multimodal-rag-search-go'),
                tooltip: 'Search',
                onPressed: () => onSearch(controller.text),
                icon: const Icon(Icons.arrow_forward),
              ),
          ],
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(
            theme.colorScheme.surfaceContainerHighest,
          ),
          textInputAction: TextInputAction.search,
          // Search as you type, once typing pauses.
          onChanged: vm.queryChanged,
          onSubmitted: onSearch,
        ),
        const SizedBox(height: 12),
        _Suggestions(
          keyPrefix: 'multimodal-rag-suggestion',
          suggestions: kMultimodalRagSuggestions,
          onTap: onSearch,
        ),
        if (query != null) ...[
          const SizedBox(height: 8),
          _SectionHeader(
            results.isEmpty
                ? 'NO STRONG MATCH FOR “$query”'
                : '${vm.similarTo == null ? '' : '${query.toUpperCase()} · '}'
                      '${results.length} RESULT${results.length == 1 ? '' : 'S'}'
                      '${vm.searchTook == null ? '' : ' · ${shortDuration(vm.searchTook!)}'}',
            trailing: Text(
              vm.similarTo == null ? 'text · images · audio' : 'image → image',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final (i, result) in results.indexed)
            _Appear(
              key: ValueKey('$query-${result.item.id}'),
              delay: Duration(milliseconds: 70 * i),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ResultCard(
                  key: Key('multimodal-rag-result-$i'),
                  vm: vm,
                  result: result,
                  query: query,
                  rank: i + 1,
                ),
              ),
            ),
          if (results.isEmpty)
            Text(
              'Nothing stands out from the rest of its kind. Try one of the '
              'suggestions.',
              style: theme.textTheme.bodyMedium,
            ),
        ] else if (vm.indexedCount == 0)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: _EmptyHint(
              icon: Icons.collections_bookmark_outlined,
              text: 'Index the library first (Library tab).',
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: _EmptyHint(
              icon: Icons.travel_explore,
              text:
                  'One query, three kinds of memory: notes by their words, '
                  'photos by their pixels, voice memos by their sound.',
            ),
          ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    super.key,
    required this.vm,
    required this.result,
    required this.query,
    required this.rank,
  });

  final MultimodalRagViewModel vm;
  final MultimodalRagResult result;
  final String query;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = result.item;
    final hit = result.hit;
    final color = kindColor(item.kind, theme.brightness);
    final leading = switch (item) {
      PhotoItem(:final reference) => MultimodalRagThumb(
        image: vm.imageFor(reference),
        size: 72,
      ),
      MemoItem() => MemoPlayButton(vm: vm, memo: item, size: 52),
      NoteItem() => const _KindBadge(kind: MultimodalRagKind.note, size: 52),
    };
    final snippet = switch (item) {
      NoteItem(:final body) => body,
      MemoItem() => 'Found by what is said in it — no transcript',
      PhotoItem() => 'Found by what is in the picture — no caption, no OCR',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(kindIcon(item.kind), size: 14, color: color),
                          const SizedBox(width: 4),
                          Text(
                            [
                              item.kind.label.toUpperCase(),
                              if (item case MemoItem(:final duration))
                                clock(duration),
                            ].join(' · '),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '#$rank',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.title,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      _Highlighted(
                        text: snippet,
                        query: item is NoteItem ? query : '',
                        color: color,
                      ),
                      if (item case PhotoItem photo)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: Key('multimodal-rag-similar-${photo.id}'),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: vm.searching
                                ? null
                                : () => vm.findSimilar(photo),
                            icon: const Icon(Icons.image_search, size: 18),
                            label: const Text('Find similar'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _RelevanceBar(hit: hit, color: color),
          ],
        ),
      ),
    );
  }
}

class _Highlighted extends StatelessWidget {
  const _Highlighted({
    required this.text,
    required this.query,
    required this.color,
  });

  final String text;
  final String query;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.35,
    );
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          for (final part in highlight(text, query))
            TextSpan(
              text: part.text,
              style: part.match
                  ? TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                      backgroundColor: color.withValues(alpha: 0.22),
                    )
                  : null,
            ),
        ],
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// How far a hit stands out from the rest of its kind (its lift, see
/// multimodal_rag_ranking.dart), with the raw cosine beside it.
class _RelevanceBar extends StatelessWidget {
  const _RelevanceBar({required this.hit, required this.color});

  final RankedHit hit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: hit.strength),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 6,
                color: color,
                backgroundColor: color.withValues(alpha: 0.14),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'cos ${hit.similarity.toStringAsFixed(2)}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
