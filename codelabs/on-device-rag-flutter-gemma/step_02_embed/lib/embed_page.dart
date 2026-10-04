import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';
import 'recipes.dart';

/// Step 2: turn the corpus into vectors, and look at one.
///
/// Nothing is stored yet — the vectors live in this widget's state and are
/// gone when you leave the page. That is on purpose: Step 3 is where a vector
/// store arrives, and it is easier to see what a store buys you once you have
/// held the raw output in your hand.
class EmbedPage extends StatefulWidget {
  const EmbedPage({super.key, required this.hfToken});

  /// Same token as the LLM download. EmbeddingGemma sits behind the same
  /// licence gate, so one `--dart-define=HF_TOKEN=...` covers both.
  final String hfToken;

  @override
  State<EmbedPage> createState() => _EmbedPageState();
}

class _EmbedPageState extends State<EmbedPage> {
  static const _embedder = Embedders.embeddingGemma;

  String _status = 'The recipes are plain text until you embed them.';
  double? _installProgress;
  bool _busy = false;
  String? _error;

  /// recipe id -> its vector. Held here, and nowhere else.
  final Map<String, List<double>> _vectors = {};

  /// Which recipe the inspector below is showing.
  String _selected = kRecipes.first.id;

  Future<void> _embedAll() async {
    setState(() {
      _busy = true;
      _error = null;
      _vectors.clear();
      _status = 'Installing ${_embedder.label}...';
    });

    try {
      // install() is idempotent: the bytes are fetched once and the second
      // run of this button skips straight past it.
      await FlutterEdgeAi.installEmbedder()
          .modelFromNetwork(
            _embedder.modelUrl,
            token: widget.hfToken.isEmpty ? null : widget.hfToken,
          )
          .tokenizerFromNetwork(
            _embedder.tokenizerUrl,
            token: widget.hfToken.isEmpty ? null : widget.hfToken,
          )
          .withModelProgress((p) {
            if (mounted) setState(() => _installProgress = p / 100);
          })
          .install();

      if (!mounted) return;
      setState(() {
        _installProgress = null;
        _status = 'Embedding ${kRecipes.length} recipes...';
      });

      final embedder = await FlutterEdgeAi.getActiveEmbedder();

      // One call for the whole corpus rather than a loop: the worker isolate
      // is set up once and the model stays resident between texts.
      //
      // `retrievalDocument` is the half of the asymmetry that matters here.
      // EmbeddingGemma was trained with a different prefix for documents than
      // for queries, and the enum is where that lives:
      //
      //   retrievalDocument -> 'title: none | text: '
      //   retrievalQuery    -> 'task: search result | query: '
      //
      // Index with the query prefix and nothing errors — the vectors just land
      // slightly off, and every search afterwards is a little worse for a
      // reason no exception will ever point at.
      final vectors = await embedder.generateEmbeddings(
        kRecipes.map((r) => r.text).toList(),
        taskType: TaskType.retrievalDocument,
      );

      if (!mounted) return;
      setState(() {
        for (var i = 0; i < kRecipes.length; i++) {
          _vectors[kRecipes[i].id] = vectors[i];
        }
        _status = 'Embedded ${kRecipes.length} recipes.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _installProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final vector = _vectors[_selected];

    return Scaffold(
      appBar: AppBar(title: const Text('Recipes')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
                  onPressed: _busy ? null : _embedAll,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(
                    _vectors.isEmpty
                        ? 'Embed the corpus (${_embedder.sizeLabel} download '
                              'on first run)'
                        : 'Embed again',
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: kRecipes.length,
              itemBuilder: (context, i) {
                final r = kRecipes[i];
                final done = _vectors.containsKey(r.id);
                return ListTile(
                  selected: r.id == _selected,
                  onTap: () => setState(() => _selected = r.id),
                  leading: Icon(
                    done ? Icons.check_circle : Icons.circle_outlined,
                    color: done ? Colors.green : null,
                  ),
                  title: Text(r.title),
                  subtitle: Text(
                    '${r.cuisine} · ${r.minutes} min'
                    '${r.vegetarian ? ' · vegetarian' : ''}',
                  ),
                );
              },
            ),
          ),
          if (vector != null) _VectorInspector(vector: vector),
        ],
      ),
    );
  }
}

/// What an embedding actually is, with the numbers on screen.
class _VectorInspector extends StatelessWidget {
  const _VectorInspector({required this.vector});

  final List<double> vector;

  @override
  Widget build(BuildContext context) {
    final head = vector.take(6).map((v) => v.toStringAsFixed(4)).join(', ');

    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${vector.length} dimensions',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '[$head, ...]',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            'That is the whole representation. Two recipes are "similar" when '
            'these two lists of numbers point in a similar direction — which '
            'is all a vector search ever computes.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
