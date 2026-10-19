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
    home: const BuiltInAiPage(),
  );
}

class BuiltInAiPage extends StatefulWidget {
  const BuiltInAiPage({super.key});

  @override
  State<BuiltInAiPage> createState() => _BuiltInAiPageState();
}

class _BuiltInAiPageState extends State<BuiltInAiPage>
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

  /// Only a probe writes the card. A new status replaces whatever error
  /// described the old one.
  void _showStatus(BuiltInAiAvailability status) {
    setState(() {
      if (status != _availability) _error = null;
      _availability = status;
    });
  }

  /// An action failed: ask the device again, then say what failed, so the new
  /// status cannot wipe the message.
  Future<void> _failed(String message) async {
    await _checkAvailability();
    if (mounted) setState(() => _error = message);
  }

  // Keep this call directly attached to the tap for the web user-gesture gate.
  Future<void> _prepare() async {
    setState(() {
      _error = null;
      _progress = null;
      _preparing = true;
    });
    String? failure;
    try {
      await BuiltInAi.ensureReady(
        onProgress: (percent) {
          if (mounted) setState(() => _progress = percent);
        },
      );
      // ensureReady returns only once the model is available, so it answers
      // like a probe.
      _probe++;
      if (mounted) _showStatus(BuiltInAiAvailability.available);
    } on BuiltInAiUnavailableException catch (error) {
      failure = error.status == BuiltInAiAvailability.downloadable
          // Still downloadable, so the download never started: on the web,
          // Chrome starts it only from a tap.
          ? 'The download did not start. Choose Prepare again.'
          : 'Preparing stopped: the device reported the model as unavailable.';
    } on TimeoutException {
      failure =
          'The model is still not ready after 10 minutes. The download may '
          'still be running: check again later.';
    } catch (error, stackTrace) {
      failure = 'Could not prepare: $error';
      _report(error, stackTrace, 'while preparing the built-in AI model');
    } finally {
      if (mounted) {
        setState(() {
          _preparing = false;
          _progress = null;
        });
      }
    }
    if (failure != null) await _failed(failure);
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
    final working = _preparing;

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
                            ? 'Checking the device…'
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
                              ? 'Preparing the model…'
                              : 'Preparing: $_progress%',
                        ),
                      ],
                      if (!unsupported && status != null) ...[
                        const SizedBox(height: 12),
                        if (status.isTransient)
                          FilledButton(
                            onPressed: working ? null : _prepare,
                            child: Text(prepareLabel),
                          ),
                        if (!ready) ...[
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: working ? null : _checkAvailability,
                            child: const Text('Check again'),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Step 3 opens a model and enables the composer.
              const TextField(
                enabled: false,
                decoration: InputDecoration(
                  labelText: 'Prompt',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const FilledButton(onPressed: null, child: Text('Ask')),
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
/// platform gets its own remedy. The web and Android never report
/// `unavailableOsTooOld` or `unavailableDisabled`.
String statusMessage(BuiltInAiAvailability status) => switch ((status, _host)) {
  (BuiltInAiAvailability.available, _) => 'Built-in AI is ready.',
  (BuiltInAiAvailability.downloadable, _Host.web) =>
    'Chrome has to download its model once, several GB, over an unmetered '
        'connection. Choose Prepare to start.',
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
    'This browser has no Prompt API. Open the page at localhost or over '
        'HTTPS in desktop Chrome 148 or newer.',
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _Host.android) =>
    "AICore reports Gemini Nano as unavailable: this phone is not on Google's "
        'Prompt API device list, its bootloader is unlocked, or AICore has '
        'not finished setting it up. On a listed phone, stay online and check '
        'again later.',
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _Host.apple) =>
    'This device does not support Apple Intelligence.',
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _) =>
    'This device has no built-in AI model.',
  (BuiltInAiAvailability.unavailableOsTooOld, _Host.apple) =>
    'Built-in AI needs iOS or macOS 26, and an app built with Xcode 26.',
  (BuiltInAiAvailability.unavailableOsTooOld, _) =>
    'Update the operating system to use built-in AI.',
  (BuiltInAiAvailability.unavailableDisabled, _Host.apple) =>
    'Turn on Apple Intelligence in Settings, then check again.',
  (BuiltInAiAvailability.unavailableDisabled, _) =>
    'Built-in AI is turned off in the system settings. Turn it on, then '
        'check again.',
  (BuiltInAiAvailability.unavailableOther, _Host.web) =>
    'Chrome cannot run its model here. Check that on-device AI is on in '
        'Chrome Settings → System and not turned off by the '
        'GenAILocalFoundationalModelSettings policy. Otherwise this computer '
        'is below the floor: 22 GB of free disk, and a GPU with more than '
        '4 GB of VRAM or 16 GB of RAM and 4 CPU cores.',
  (BuiltInAiAvailability.unavailableOther, _Host.android) =>
    'Google AICore is missing, out of date or not set up yet, or this is an '
        'emulator. Update AICore from the Play Store, then reinstall this '
        'app. On a phone set up recently, AICore can need minutes to hours, '
        'and a restart can help: check again later.',
  (BuiltInAiAvailability.unavailableOther, _Host.windows) =>
    'Phi Silica needs a packaged app with package identity and the '
        'systemAIModels capability, the Windows App Runtime and, on the '
        'stable channel, a Limited Access Feature token. flutter run gives '
        'it none of these.',
  (BuiltInAiAvailability.unavailableOther, _) =>
    'Built-in AI could not be reached. Check again in a moment.',
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
