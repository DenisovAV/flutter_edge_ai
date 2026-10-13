import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterEdgeAi.initialize(inferenceEngines: const [BuiltInAiEngine()]);
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

class _AvailabilityPageState extends State<AvailabilityPage> {
  BuiltInAiAvailability? _status;
  int? _progress;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
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
      _progress = 0;
    });
    try {
      await BuiltInAi.ensureReady(
        onProgress: (percent) {
          if (mounted) setState(() => _progress = percent);
        },
      );
      await _checkAvailability();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final unsupported = BuiltInAiModels.forCurrentPlatform == null;
    final canPrepare =
        !unsupported &&
        status != null &&
        status != BuiltInAiAvailability.available &&
        !status.name.startsWith('unavailable');

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
                          : 'Built-in AI is ${status.name}.',
                    ),
                    if (_progress case final percent?) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(value: percent / 100),
                      const SizedBox(height: 8),
                      Text('Preparing: $percent%'),
                    ],
                    if (_error case final error?) ...[
                      const SizedBox(height: 16),
                      Text('Could not prepare the model: $error'),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: canPrepare && _progress == null
                          ? _prepare
                          : null,
                      child: const Text('Prepare built-in AI'),
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
