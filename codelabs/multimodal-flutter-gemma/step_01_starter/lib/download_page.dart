import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';

/// Installs the model file, reporting progress as it goes.
///
/// Nothing here is Gemma-specific: `installModel` takes the model's identity
/// (what it is) and `fromNetwork` takes the source (where the bytes are).
class DownloadPage extends StatefulWidget {
  const DownloadPage({
    super.key,
    required this.model,
    required this.onInstalled,
  });

  final ModelChoice model;

  /// Called once the model is installed, so the app can move on.
  final VoidCallback onInstalled;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  int _percent = 0;
  bool _downloading = false;
  Object? _error;

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
    });

    try {
      await FlutterEdgeAi.installModel(
            // What the model IS — the engine bakes in the chat template;
            // modelType instead drives thinking-tag stripping & tool parsing.
            modelType: widget.model.modelType,
            // Which runtime reads it. `.litertlm` routes to LiteRtLmEngine;
            // the default is `task` (MediaPipe), so this line is load-bearing.
            fileType: ModelFileType.litertlm,
          )
          // No `token:` here — the Hugging Face token passed to
          // FlutterEdgeAi.initialize() is attached automatically, and only to
          // URLs whose host contains `huggingface.co`, so it does not ride
          // along to the other hosts an app downloads from.
          .fromNetwork(widget.model.url)
          .withProgress((percent) {
            if (mounted) setState(() => _percent = percent);
          })
          .install();

      if (mounted) widget.onInstalled();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Get the model')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.model.label, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  '${widget.model.sizeLabel} — downloaded once, then it lives '
                  'on the device and runs with the network off.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                if (_downloading) ...[
                  LinearProgressIndicator(value: _percent / 100),
                  const SizedBox(height: 8),
                  Text('$_percent%', textAlign: TextAlign.center),
                ] else
                  FilledButton(
                    onPressed: _download,
                    child: const Text('Download model'),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  _ErrorCard(
                    error: _error!,
                    requiresToken: widget.model.requiresToken,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A failed download is usually one of two things, and the message says which.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.requiresToken});

  final Object error;
  final bool requiresToken;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The plugin reports a failed download as a typed `DownloadException`
    // wrapping a sealed `DownloadError`, so match on the type rather than
    // sniffing the message for "401".
    final (title, body) = switch (error) {
      DownloadException(error: UnauthorizedError() || ForbiddenError())
          when requiresToken =>
        (
          'Hugging Face refused the download',
          'Accept the model licence on its Hugging Face page, then run with '
              '--dart-define=HF_TOKEN=hf_your_token.',
        ),
      DownloadException(:final error) => (
        'Download failed',
        error.toUserMessage(),
      ),
      _ => ('Download failed', '$error'),
    };

    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(body),
          ],
        ),
      ),
    );
  }
}
