import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterEdgeAi.initialize(
    inferenceEngines: const [BuiltInAiEngine()],
    webStorageMode: WebStorageMode.streaming,
  );
  runApp(const BuiltInAiApp());
}

class BuiltInAiApp extends StatelessWidget {
  const BuiltInAiApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Built-in AI',
    theme: ThemeData(colorSchemeSeed: Colors.deepPurple),
    home: const AvailabilityPage(),
  );
}

class AvailabilityPage extends StatefulWidget {
  const AvailabilityPage({super.key});

  @override
  State<AvailabilityPage> createState() => _AvailabilityPageState();
}

class _AvailabilityPageState extends State<AvailabilityPage>
    with WidgetsBindingObserver {
  BuiltInAiAvailability? _availability;
  int? _progress;
  String? _error;
  bool _preparing = false;

  /// Numbers each availability probe, so one that returns late (a probe can
  /// take up to 20 seconds) cannot overwrite a newer answer.
  int _probe = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAvailability();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The reader may have turned Apple Intelligence on, or off, in Settings.
    if (state == AppLifecycleState.resumed) _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    final probe = ++_probe;
    final status = await BuiltInAi.availability();
    if (mounted && probe == _probe) _showStatus(status);
  }

  /// A new status replaces whatever error described the old one.
  void _showStatus(BuiltInAiAvailability status) {
    setState(() {
      if (status != _availability) _error = null;
      _availability = status;
    });
  }

  /// The OS refused: show the status it gave, then ask again.
  void _showUnavailable(BuiltInAiUnavailableException error) {
    if (!mounted) return;
    _probe++;
    _showStatus(error.status);
    if (error.status.isTransient) {
      // Still downloadable, so the download did not start: on the web, Chrome
      // starts it only from a tap. The status alone would not say so.
      setState(() => _error = 'The download did not start: ${error.message}');
    }
    unawaited(_checkAvailability());
  }

  // Keep this call directly attached to the tap for the web user-gesture gate.
  Future<void> _prepare() async {
    setState(() {
      _error = null;
      _progress = null;
      _preparing = true;
    });
    try {
      await BuiltInAi.ensureReady(
        onProgress: (percent) {
          if (mounted) setState(() => _progress = percent);
        },
      );
    } on BuiltInAiUnavailableException catch (error) {
      _showUnavailable(error);
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _error =
              'The model is still not ready after 10 minutes. The OS keeps '
              'preparing it in the background: check again later.',
        );
      }
    } catch (error, stackTrace) {
      if (mounted) setState(() => _error = 'Could not prepare: $error');
      _report(error, stackTrace, 'while preparing the built-in AI model');
    } finally {
      if (mounted) {
        setState(() {
          _preparing = false;
          _progress = null;
        });
        await _checkAvailability();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _availability;
    final unsupported = BuiltInAiModels.forCurrentPlatform == null;
    final ready = status == BuiltInAiAvailability.available;

    return Scaffold(
      appBar: AppBar(title: const Text('Built-in AI')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Device status',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        unsupported
                            ? 'This platform has no built-in AI model.'
                            : status == null
                            ? 'Checking the operating system…'
                            : statusMessage(status),
                        key: const Key('status'),
                      ),
                      if (_preparing) ...[
                        const SizedBox(height: 12),
                        // Indeterminate until the first progress event: Apple
                        // never reports one, Android only for a download this
                        // call started.
                        LinearProgressIndicator(
                          value: _progress == null ? null : _progress! / 100,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _progress == null
                              ? 'Preparing the OS model…'
                              : 'Preparing: $_progress%',
                        ),
                      ],
                      if (!unsupported && status != null) ...[
                        const SizedBox(height: 12),
                        if (status.isTransient)
                          FilledButton(
                            onPressed: _preparing ? null : _prepare,
                            child: Text(prepareLabel),
                          ),
                        if (!ready) ...[
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: _preparing ? null : _checkAvailability,
                            child: const Text('Check again'),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 16),
                Text(error, key: const Key('error')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _Host { web, android, apple, windows, other }

_Host get _host {
  if (kIsWeb) return _Host.web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => _Host.android,
    TargetPlatform.iOS || TargetPlatform.macOS => _Host.apple,
    TargetPlatform.windows => _Host.windows,
    _ => _Host.other,
  };
}

/// On Apple the download starts when the user turns Apple Intelligence on,
/// so Prepare only waits for it; elsewhere it starts a download.
String get prepareLabel => _host == _Host.apple
    ? 'Wait for the model'
    : 'Prepare built-in AI (downloads several GB)';

/// One status means different things on different platforms, so each
/// platform gets its own remedy.
String statusMessage(BuiltInAiAvailability status) => switch ((status, _host)) {
  (BuiltInAiAvailability.available, _) => 'Built-in AI is ready.',
  (BuiltInAiAvailability.downloadable, _Host.web) =>
    'Chrome has to download its model once, several GB. '
        'Choose Prepare to start.',
  (BuiltInAiAvailability.downloadable, _) =>
    'The OS has to download its model once, several GB; Wi-Fi is best. '
        'Choose Prepare to start.',
  (BuiltInAiAvailability.downloading, _Host.web) =>
    'Chrome is downloading its model. Choose Prepare to wait for it.',
  (BuiltInAiAvailability.downloading, _Host.apple) =>
    'Apple Intelligence is still preparing its model, which can take a '
        'while after it is turned on. Keep the device online, then check '
        'again.',
  (BuiltInAiAvailability.downloading, _) =>
    'The OS is downloading its model. Choose Prepare to wait for it.',
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _Host.web) =>
    'This browser has no Prompt API. Open the page in desktop Chrome 148 '
        'or newer.',
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _Host.android) =>
    "AICore reports Gemini Nano as unavailable: this phone is not on Google's "
        'Prompt API device list, or AICore has not finished setting it up. '
        'On a listed phone, stay online and check again later.',
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _Host.apple) =>
    'This device does not support Apple Intelligence.',
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _) =>
    'This device has no built-in AI model.',
  (BuiltInAiAvailability.unavailableOsTooOld, _Host.apple) =>
    'Built-in AI needs iOS or macOS 26, and an app built with Xcode 26.',
  (BuiltInAiAvailability.unavailableOsTooOld, _Host.web) =>
    'Update Chrome to use the Prompt API.',
  (BuiltInAiAvailability.unavailableOsTooOld, _) =>
    'Update the operating system to use built-in AI.',
  (BuiltInAiAvailability.unavailableDisabled, _Host.apple) =>
    'Turn on Apple Intelligence in Settings, then check again.',
  (BuiltInAiAvailability.unavailableDisabled, _) =>
    'Built-in AI is turned off in the system settings. Turn it on, then '
        'check again.',
  (BuiltInAiAvailability.unavailableOther, _Host.web) =>
    'Chrome cannot run its model on this computer. It needs 22 GB of free '
        'disk, and a GPU with more than 4 GB of VRAM or 16 GB of RAM and '
        '4 CPU cores.',
  (BuiltInAiAvailability.unavailableOther, _Host.android) =>
    'Google AICore is missing or out of date, or this is an emulator. '
        'Update AICore from the Play Store, then check again.',
  (BuiltInAiAvailability.unavailableOther, _Host.windows) =>
    'Phi Silica needs a packaged app with package identity, which '
        '`flutter run` does not give it.',
  (BuiltInAiAvailability.unavailableOther, _) =>
    'Built-in AI could not be reached. The debug console says why.',
};

void _report(Object error, StackTrace stackTrace, String context) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'builtin_ai_codelab',
      context: ErrorDescription(context),
    ),
  );
}
