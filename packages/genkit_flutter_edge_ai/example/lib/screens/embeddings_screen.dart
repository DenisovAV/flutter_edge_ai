import 'package:flutter/material.dart';

import '../app_state.dart';
import '../widgets/status_banner.dart';

class EmbeddingsScreen extends StatefulWidget {
  final AppState appState;
  final VoidCallback onGoToSettings;

  const EmbeddingsScreen({
    super.key,
    required this.appState,
    required this.onGoToSettings,
  });

  @override
  State<EmbeddingsScreen> createState() => _EmbeddingsScreenState();
}

class _EmbeddingsScreenState extends State<EmbeddingsScreen> {
  final _queryController = TextEditingController(
    text: 'Which planet is known as the Red Planet',
  );
  final _similarController = TextEditingController(
    text: 'Mars is famous for its reddish appearance',
  );
  final _differentController = TextEditingController(
    text: 'The stock market closed higher today',
  );

  bool _computing = false;

  Future<void> _compute() async {
    setState(() => _computing = true);
    await widget.appState.computeSimilarity([
      _queryController.text,
      _similarController.text,
      _differentController.text,
    ]);
    if (mounted) setState(() => _computing = false);
  }

  @override
  void dispose() {
    _queryController.dispose();
    _similarController.dispose();
    _differentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        final state = widget.appState;

        return Column(
          children: [
            if (!state.embedderInstalled)
              StatusBanner(
                message: 'Embedder model not installed.',
                onAction: widget.onGoToSettings,
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _queryController,
                    decoration: const InputDecoration(
                      labelText: 'Query text',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _similarController,
                    decoration: const InputDecoration(
                      labelText: 'Similar text',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _differentController,
                    decoration: const InputDecoration(
                      labelText: 'Different text',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed:
                        state.embedderInstalled && !_computing ? _compute : null,
                    child: _computing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Compute Similarity'),
                  ),
                  const SizedBox(height: 24),
                  if (state.embeddingResults.isNotEmpty) ...[
                    Text('Results (cosine similarity to query):',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    for (final result in state.embeddingResults)
                      _buildResultCard(context, result),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildResultCard(BuildContext context, EmbeddingResult result) {
    final color = result.similarity > 0.7
        ? Colors.green
        : result.similarity > 0.4
            ? Colors.orange
            : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          result.label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          result.similarity.toStringAsFixed(4),
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        subtitle: LinearProgressIndicator(
          value: result.similarity.clamp(0.0, 1.0),
          color: color,
          backgroundColor: color.withValues(alpha: 0.2),
        ),
      ),
    );
  }
}
