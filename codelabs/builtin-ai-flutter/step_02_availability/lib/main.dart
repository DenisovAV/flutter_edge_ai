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
  BuiltInAiAvailability? _status;
  int? _progress;
  bool _preparing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAvailability();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    final status = await BuiltInAi.availability();
    if (mounted) setState(() => _status = status);
  }

  // On web this must be called directly by the button: the browser requires
  // a user gesture before it starts downloading its built-in model.
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
      await _checkAvailability();
    } on BuiltInAiUnavailableException catch (error) {
      if (mounted) setState(() => _error = _statusMessage(error.status));
    } finally {
      if (mounted) {
        setState(() {
          _preparing = false;
          _progress = null;
        });
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
    final status = _status;
    final unsupported = BuiltInAiModels.forCurrentPlatform == null;
    final canPrepare = !unsupported && status?.isTransient == true;

    return Scaffold(
      appBar: AppBar(title: const Text('Built-in AI')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Device status',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      unsupported
                          ? 'This platform has no built-in AI model.'
                          : status == null
                          ? 'Checking the operating system…'
                          : _statusMessage(status),
                      key: const Key('status'),
                    ),
                    if (_preparing) ...[
                      const SizedBox(height: 16),
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
                    if (_error case final error?) ...[
                      const SizedBox(height: 16),
                      Text(error),
                    ],
                    const SizedBox(height: 20),
                    if (canPrepare)
                      FilledButton(
                        onPressed: _preparing ? null : _prepare,
                        child: const Text(
                          'Prepare built-in AI (downloads may be several GB)',
                        ),
                      )
                    else
                      OutlinedButton(
                        onPressed: _preparing ? null : _checkAvailability,
                        child: const Text('Check again'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _statusMessage(BuiltInAiAvailability status) => switch (status) {
  BuiltInAiAvailability.available => 'Built-in AI is ready.',
  BuiltInAiAvailability.downloadable =>
    'The OS model needs to be downloaded. Choose Prepare to continue.',
  BuiltInAiAvailability.downloading =>
    'The OS is downloading the model. Choose Prepare to wait for it.',
  BuiltInAiAvailability.unavailableDeviceUnsupported =>
    'This device cannot run its OS built-in AI model.',
  BuiltInAiAvailability.unavailableOsTooOld =>
    'Update the operating system to use built-in AI.',
  BuiltInAiAvailability.unavailableDisabled =>
    'Turn on Apple Intelligence or the system AI feature, then check again.',
  BuiltInAiAvailability.unavailableOther =>
    'Built-in AI could not be reached. Check the platform setup and try again.',
};
