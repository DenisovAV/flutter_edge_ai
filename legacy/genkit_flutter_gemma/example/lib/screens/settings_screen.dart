import 'package:flutter/material.dart';

import '../app_state.dart';

class SettingsScreen extends StatefulWidget {
  final AppState appState;

  const SettingsScreen({super.key, required this.appState});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _tokenController;
  late final TextEditingController _inferenceUrlController;
  late final TextEditingController _embedderModelUrlController;
  late final TextEditingController _embedderTokenizerUrlController;

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(text: widget.appState.hfToken);
    _inferenceUrlController =
        TextEditingController(text: widget.appState.inferenceUrl);
    _embedderModelUrlController =
        TextEditingController(text: widget.appState.embedderModelUrl);
    _embedderTokenizerUrlController =
        TextEditingController(text: widget.appState.embedderTokenizerUrl);
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _inferenceUrlController.dispose();
    _embedderModelUrlController.dispose();
    _embedderTokenizerUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.appState,
      builder: (context, _) {
        final state = widget.appState;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // HuggingFace Token
            Text('HuggingFace Token',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenController,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'hf_...',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
              onChanged: (v) => state.hfToken = v,
            ),

            const SizedBox(height: 24),

            // Inference Model
            Text('Inference Model',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _inferenceUrlController,
              decoration: const InputDecoration(
                labelText: 'Model URL',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
              onChanged: (v) => state.inferenceUrl = v,
            ),
            const SizedBox(height: 8),
            _buildModelStatus(
              installed: state.inferenceInstalled,
              downloading: state.isDownloadingInference,
              progress: state.inferenceProgress,
              onDownload: state.downloadInferenceModel,
            ),

            const SizedBox(height: 24),

            // Embedder Model
            Text('Embedder Model',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _embedderModelUrlController,
              decoration: const InputDecoration(
                labelText: 'Model URL',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
              onChanged: (v) => state.embedderModelUrl = v,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _embedderTokenizerUrlController,
              decoration: const InputDecoration(
                labelText: 'Tokenizer URL',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
              onChanged: (v) => state.embedderTokenizerUrl = v,
            ),
            const SizedBox(height: 8),
            _buildModelStatus(
              installed: state.embedderInstalled,
              downloading: state.isDownloadingEmbedder,
              progress: state.embedderProgress,
              onDownload: state.downloadEmbedderModel,
            ),

            const SizedBox(height: 24),

            // Model Config
            Text('Model Config',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Max Tokens: '),
                Expanded(
                  child: Slider(
                    value: state.maxTokens.toDouble(),
                    min: 64,
                    max: 4096,
                    divisions: 63,
                    label: state.maxTokens.toString(),
                    onChanged: (v) {
                      state.maxTokens = v.round();
                    },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(state.maxTokens.toString(),
                      textAlign: TextAlign.end),
                ),
              ],
            ),

            const SizedBox(height: 16),

            FilledButton.icon(
              onPressed: state.reinitializeGenkit,
              icon: const Icon(Icons.refresh),
              label: const Text('Re-initialize Genkit'),
            ),

            if (state.error != null) ...[
              const SizedBox(height: 16),
              Text(
                state.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildModelStatus({
    required bool installed,
    required bool downloading,
    required int progress,
    required VoidCallback onDownload,
  }) {
    if (installed) {
      return Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green[400]),
          const SizedBox(width: 8),
          const Text('Installed'),
        ],
      );
    }

    if (downloading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: progress / 100),
          const SizedBox(height: 4),
          Text('Downloading $progress%'),
        ],
      );
    }

    return FilledButton.tonal(
      onPressed: onDownload,
      child: const Text('Download'),
    );
  }
}
