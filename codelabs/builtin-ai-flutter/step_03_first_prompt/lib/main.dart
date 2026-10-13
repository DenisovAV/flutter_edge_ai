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
    home: const PromptPage(),
  );
}

class PromptPage extends StatefulWidget {
  const PromptPage({super.key});

  @override
  State<PromptPage> createState() => _PromptPageState();
}

class _PromptPageState extends State<PromptPage> {
  final _prompt = TextEditingController(text: 'Explain on-device AI simply.');
  InferenceModel? _model;
  InferenceModelSession? _session;
  String _status = 'Check and prepare the OS model to begin.';
  String _answer = '';
  bool _busy = false;

  Future<void> _start() async {
    final spec = BuiltInAiModels.forCurrentPlatform;
    if (spec == null) {
      setState(() => _status = 'This platform has no built-in AI model.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Preparing the OS model…';
    });
    try {
      // This is the first awaited call so a web button tap remains a user
      // gesture while the browser starts its model download.
      await BuiltInAi.ensureReady(
        onProgress: (percent) {
          if (mounted) setState(() => _status = 'Preparing: $percent%');
        },
      );
      await FlutterEdgeAi.installModel(
        modelType: spec.modelType,
        fileType: ModelFileType.builtIn,
      ).fromBundled(spec.name).install();
      final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
      final session = await model.createSession();
      if (!mounted) {
        await session.close();
        await model.close();
        return;
      }
      setState(() {
        _model = model;
        _session = session;
        _status = 'Built-in AI is ready.';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'Could not start: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ask() async {
    final session = _session;
    final text = _prompt.text.trim();
    if (session == null || text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _answer = '';
    });
    try {
      await session.addQueryChunk(Message.text(text: text, isUser: true));
      final answer = await session.getResponse();
      if (mounted) setState(() => _answer = answer);
    } catch (error) {
      if (mounted) setState(() => _answer = 'Request failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _session?.close().catchError((Object _) {});
    _model?.close().catchError((Object _) {});
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My first OS-model prompt')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(_status, key: const Key('status')),
            const SizedBox(height: 16),
            if (_session == null)
              FilledButton(
                onPressed: _busy ? null : _start,
                child: const Text('Start built-in AI'),
              )
            else ...[
              TextField(
                controller: _prompt,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Prompt',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _ask,
                child: const Text('Ask'),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            if (_answer.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Answer', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              SelectableText(_answer),
            ],
          ],
        ),
      ),
    ),
  );
}
