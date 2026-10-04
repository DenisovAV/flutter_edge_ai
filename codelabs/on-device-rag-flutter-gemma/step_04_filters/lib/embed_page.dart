import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';
import 'rag_store.dart';
import 'recipes.dart';

/// Step 3: index the corpus into a vector store, then search it.
///
/// The page looks like Step 2's, and the difference is the part you cannot
/// see: the vectors are in a database now. Index once, kill the app, come
/// back — the row count at the top is still twelve, and searching works
/// without embedding anything again.
class EmbedPage extends StatefulWidget {
  const EmbedPage({super.key, required this.hfToken});

  final String hfToken;

  @override
  State<EmbedPage> createState() => _EmbedPageState();
}

class _EmbedPageState extends State<EmbedPage> {
  final _query = TextEditingController();

  String _status = 'Opening the store...';
  double? _installProgress;
  bool _busy = true;
  String? _error;

  VectorStoreStats? _stats;
  List<RetrievalResult>? _hits;

  // The three filter controls, one per declared field.
  final Set<String> _cuisines = {};
  int? _maxMinutes;
  bool _vegetarianOnly = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final stats = await RagStore.open();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _status = stats.documentCount == 0
            ? 'The store is empty. Index the corpus to search it.'
            : 'Store already holds ${stats.documentCount} recipes — from a '
                  'previous run, not from this one.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _index() async {
    setState(() {
      _busy = true;
      _error = null;
      _hits = null;
      _status = 'Installing ${Embedders.embeddingGemma.label}...';
    });
    try {
      await installEmbedder(
        onProgress: (p) {
          if (mounted) setState(() => _installProgress = p);
        },
      );
      if (mounted) setState(() => _installProgress = null);

      await RagStore.index(
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      final stats = await FlutterEdgeAi.rag.stats();
      if (mounted) setState(() => _stats = stats);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _installProgress = null;
        });
      }
    }
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Searching...';
    });
    try {
      final hits = await RagStore.search(
        q,
        filter: buildFilter(
          cuisines: _cuisines,
          maxMinutes: _maxMinutes,
          vegetarianOnly: _vegetarianOnly,
        ),
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _status = hits.isEmpty
            ? 'Nothing cleared the similarity threshold.'
            : '${hits.length} hits.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final indexed = (_stats?.documentCount ?? 0) > 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recipes'),
        actions: [
          if (indexed)
            IconButton(
              tooltip: 'Empty the store',
              onPressed: _busy
                  ? null
                  : () async {
                      await RagStore.clear();
                      if (mounted) await _open();
                    },
              icon: const Icon(Icons.layers_clear),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      indexed ? Icons.storage : Icons.storage_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _stats == null
                          ? '—'
                          : '${_stats!.documentCount} rows · '
                                '${_stats!.vectorDimension} dimensions',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(_status, style: Theme.of(context).textTheme.bodyMedium),
                if (_installProgress != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _installProgress),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _index,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(
                    indexed
                        ? 'Re-index'
                        : 'Index the corpus '
                              '(${Embedders.embeddingGemma.sizeLabel} download '
                              'on first run)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _query,
                  enabled: !_busy && indexed,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    labelText: 'Ask for something to cook',
                    hintText: 'something warm with beans',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: _busy || !indexed ? null : _search,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _filterBar(),
          const Divider(height: 1),
          Expanded(child: _hits == null ? _corpusList() : _hitList()),
        ],
      ),
    );
  }

  /// One control per declared field. Change one and search again — the
  /// ranking is unchanged, the candidate set is not.
  Widget _filterBar() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final c in const ['italian', 'greek', 'indian', 'japanese'])
          FilterChip(
            label: Text(c),
            selected: _cuisines.contains(c),
            onSelected: _busy
                ? null
                : (on) => setState(
                    () => on ? _cuisines.add(c) : _cuisines.remove(c),
                  ),
          ),
        FilterChip(
          label: const Text('under 30 min'),
          selected: _maxMinutes != null,
          onSelected: _busy
              ? null
              : (on) => setState(() => _maxMinutes = on ? 30 : null),
        ),
        FilterChip(
          label: const Text('vegetarian'),
          selected: _vegetarianOnly,
          onSelected: _busy
              ? null
              : (on) => setState(() => _vegetarianOnly = on),
        ),
      ],
    ),
  );

  /// Before the first search: what is in the corpus.
  Widget _corpusList() => ListView.builder(
    itemCount: kRecipes.length,
    itemBuilder: (context, i) {
      final r = kRecipes[i];
      return ListTile(
        dense: true,
        title: Text(r.title),
        subtitle: Text(
          '${r.cuisine} · ${r.minutes} min'
          '${r.vegetarian ? ' · vegetarian' : ''}',
        ),
      );
    },
  );

  /// After a search: what came back, and how close it was.
  Widget _hitList() => ListView.builder(
    itemCount: _hits!.length,
    itemBuilder: (context, i) {
      final hit = _hits![i];
      final recipe = RagStore.recipeFor(hit);
      return ListTile(
        leading: CircleAvatar(
          child: Text(
            hit.similarity.toStringAsFixed(2),
            style: const TextStyle(fontSize: 11),
          ),
        ),
        title: Text(recipe?.title ?? hit.id),
        subtitle: Text(
          hit.content,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      );
    },
  );
}
