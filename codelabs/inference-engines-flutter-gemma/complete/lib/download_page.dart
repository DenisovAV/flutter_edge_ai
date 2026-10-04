import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';

import 'model.dart';

/// Makes [model] ready and active, whichever kind it is.
///
/// A downloaded model is fetched into app storage. A built-in one has no file:
/// the OS is asked to make its model ready (which on Android may itself be a
/// one-time download), and installing merely records which model is active.
///
/// `install()` is idempotent — on a model that is already on the device it
/// skips the download and just makes it the active one. That is how the app
/// switches engines: activate the other model.
Future<void> activate(
  ModelChoice model, {
  void Function(int)? onProgress,
}) async {
  if (model.isBuiltIn) {
    // Throws BuiltInAiUnavailableException on a device/OS that has no
    // built-in model, so the failure is typed and the caller can react.
    await BuiltInAi.ensureReady(onProgress: onProgress);
    await FlutterEdgeAi.installModel(
      modelType: model.modelType,
      fileType: model.fileType,
    ).fromBundled(model.id).install();
    return;
  }

  await FlutterEdgeAi.installModel(
        modelType: model.modelType,
        fileType: model.fileType,
      )
      .fromNetwork(model.url!)
      .withProgress((percent) => onProgress?.call(percent))
      .install();
}

/// Shows progress while [activate] runs, and offers a retry on failure.
class DownloadPage extends StatefulWidget {
  const DownloadPage({
    super.key,
    required this.model,
    required this.onReady,
    required this.onSwitch,
  });

  final ModelChoice model;
  final VoidCallback onReady;

  /// Asks the app for a different model, exactly as the chat's menu does.
  ///
  /// A retry is the only offer this screen can make on its own, and it is the
  /// wrong one when the OS simply has no built-in model: the button would
  /// re-run the same failure forever. The way out has to come from here,
  /// because this screen is the whole app until the model is ready.
  final ValueChanged<ModelChoice> onSwitch;

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  int _percent = 0;
  bool _running = false;
  Object? _error;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      await activate(
        widget.model,
        onProgress: (p) {
          if (mounted) setState(() => _percent = p);
        },
      );
      if (mounted) widget.onReady();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = widget.model;

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
                Text(model.label, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  model.isBuiltIn
                      ? 'Nothing to download — the OS ships this model. '
                            'The first use may still fetch the feature.'
                      : '${model.sizeLabel} — downloaded once, then it lives '
                            'on the device and runs with the network off.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                if (_running) ...[
                  // A file download reports bytes, so it gets a real bar. The
                  // OS feature download reports no total at all — Android
                  // sends a running byte count with `bytesTotal: 0` and Apple
                  // sends nothing — so a determinate bar there would sit at
                  // 0% and read as a frozen app.
                  LinearProgressIndicator(
                    value: model.isBuiltIn ? null : _percent / 100,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    model.isBuiltIn ? 'Preparing…' : '$_percent%',
                    textAlign: TextAlign.center,
                  ),
                ] else
                  FilledButton(
                    onPressed: _run,
                    child: Text(
                      model.isBuiltIn ? 'Use built-in model' : 'Download model',
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  _ErrorCard(
                    error: _error!,
                    model: model,
                    onSwitch: widget.onSwitch,
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

/// Three failures are common enough to name; everything else shows its text.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.error,
    required this.model,
    required this.onSwitch,
  });

  final Object error;
  final ModelChoice model;
  final ValueChanged<ModelChoice> onSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, body) = switch (error) {
      BuiltInAiUnavailableException(:final status) => (
        'This device has no built-in model',
        switch (status) {
          BuiltInAiAvailability.unavailableDisabled =>
            'The feature is turned off. Enable Apple Intelligence in '
                'Settings → Apple Intelligence & Siri on iOS, or the AICore / '
                'Gemini Nano toggle on Android.',
          BuiltInAiAvailability.unavailableOsTooOld =>
            'The OS is older than the built-in model requires.',
          _ => 'Status: $status. Switch to a downloaded model instead.',
        },
      ),
      // Download failures arrive as a typed DownloadException wrapping a
      // sealed DownloadError — match the type, do not sniff for "401".
      DownloadException(error: UnauthorizedError() || ForbiddenError())
          when model.requiresToken =>
        (
          'Hugging Face refused the download',
          'Accept the model licence on its Hugging Face page, then run with '
              '--dart-define=HF_TOKEN=hf_your_token.',
        ),
      DownloadException(:final error) => (
        'Download failed',
        error.toUserMessage(),
      ),
      _ => ('Something went wrong', '$error'),
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
            // Only the built-in model can fail with nothing left to try, so
            // only it gets this button — and it is the action the sentence
            // above promises. An error card that names a way out the screen
            // does not offer is a dead end with instructions.
            if (model.isBuiltIn) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => onSwitch(Models.downloaded),
                child: Text('Use ${Models.downloaded.label} instead'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
