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

/// The page every later step fills in: a device status card, then a composer
/// that stays disabled until there is a model.
class BuiltInAiPage extends StatelessWidget {
  const BuiltInAiPage({super.key});

  @override
  Widget build(BuildContext context) {
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
                      // Step 2 asks the device and shows its answer here.
                      const Text(
                        'The engine is registered. Next, ask the device '
                        'whether its model is ready.',
                        key: Key('status'),
                      ),
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
            ],
          ),
        ),
      ),
    );
  }
}
