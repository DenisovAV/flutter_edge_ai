import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({
    super.key,
    required this.model,
    required this.onInstalled,
  });

  final ModelChoice model;
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
      // The declared fileType — not the file name — picks the engine, and it
      // defaults to `.task`, which LiteRT-LM does not claim.
      await FlutterEdgeAi.installModel(
        modelType: widget.model.modelType,
        fileType: ModelFileType.litertlm,
      ).fromNetwork(widget.model.url).withProgress((percent) {
        if (mounted) setState(() => _percent = percent);
      }).install();
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
                  '${widget.model.sizeLabel} — downloaded once, then it runs '
                  'on the device with the network off.',
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
                  Text(
                    'The download failed.\n$_error',
                    style: TextStyle(color: theme.colorScheme.error),
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
