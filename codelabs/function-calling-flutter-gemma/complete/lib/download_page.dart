import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';

/// Installs the model, reporting progress as it goes.
///
/// Nothing here knows about tools: `installModel` takes the model's identity
/// (what it is) and the source says where the bytes are. A function-calling
/// model installs exactly like a text one — tools are a property of the
/// SESSION you open later, not of the file you install.
///
/// And nothing here knows whether the bytes travel: [ModelChoice.locate]
/// picks `fromNetwork` or `fromFile`, and a file already on disk finishes at
/// 100% immediately because there is nothing to fetch.
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

  Future<void> _install() async {
    setState(() {
      _downloading = true;
      _error = null;
    });

    try {
      await widget.model
          .locate(
            FlutterEdgeAi.installModel(
              // What the model IS — used to pick the right chat template and
              // the right function-call format.
              modelType: widget.model.modelType,
              // Which runtime reads it. `.litertlm` routes to LiteRtLmEngine;
              // the default is `task` (MediaPipe), so this line is load-bearing.
              fileType: ModelFileType.litertlm,
            ),
          )
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
    final fromDisk = widget.model.path != null;

    return Scaffold(
      appBar: AppBar(title: Text(fromDisk ? 'Use this file' : 'Get the model')),
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
                  fromDisk
                      ? '${widget.model.path}\n\nNothing is copied. The app '
                            'records where this file is and opens it there.'
                      : '${widget.model.sizeLabel} — downloaded once, then it '
                            'lives on the device and runs with the network '
                            'off.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                if (_downloading) ...[
                  LinearProgressIndicator(value: _percent / 100),
                  const SizedBox(height: 8),
                  Text('$_percent%', textAlign: TextAlign.center),
                ] else
                  FilledButton(
                    onPressed: _install,
                    child: Text(fromDisk ? 'Open it' : 'Download model'),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  _ErrorCard(error: _error!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Says what failed, in the plugin's own words where it has any.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The plugin reports a failed download as a typed `DownloadException`
    // wrapping a sealed `DownloadError`, so match on the type rather than
    // sniffing the message for a status code. A file that is not there is not
    // a download at all, and falls through to the second branch.
    final (title, body) = switch (error) {
      DownloadException(:final error) => (
        'Download failed',
        error.toUserMessage(),
      ),
      _ => ('Could not install the model', '$error'),
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
