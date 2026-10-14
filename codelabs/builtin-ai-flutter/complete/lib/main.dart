import 'dart:async';

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

class _PromptPageState extends State<PromptPage> with WidgetsBindingObserver {
  final _prompt = TextEditingController(text: 'Explain on-device AI simply.');
  BuiltInAiAvailability? _availability;
  InferenceModel? _model;
  int? _progress;
  String? _error;
  String _answer = '';
  bool _busy = false;
  bool _preparing = false;

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
    if (mounted) setState(() => _availability = status);
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

  Future<void> _start() async {
    final spec = BuiltInAiModels.forCurrentPlatform;
    if (spec == null || _availability != BuiltInAiAvailability.available) {
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    InferenceModel? model;
    try {
      await FlutterEdgeAi.installModel(
        modelType: spec.modelType,
        fileType: ModelFileType.builtIn,
      ).fromBundled(spec.name).install();
      model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
      if (!mounted) {
        await model.close();
        return;
      }
      setState(() => _model = model);
    } on BuiltInAiUnavailableException catch (error) {
      if (mounted) setState(() => _error = _statusMessage(error.status));
    } catch (error, stackTrace) {
      await model?.close();
      if (mounted) setState(() => _error = 'Could not start built-in AI.');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'builtin_ai_codelab',
          context: ErrorDescription('while opening the built-in AI model'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ask() async {
    final model = _model;
    final text = _prompt.text.trim();
    if (model == null || text.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
      _answer = '';
    });

    InferenceModelSession? session;
    try {
      // A fresh session makes each Ask independent and prevents invisible
      // history from filling the model's context window.
      session = await model.createSession();
      await session.addQueryChunk(Message.text(text: text, isUser: true));
      final answer = StringBuffer();
      await for (final chunk in session.getResponseAsync()) {
        answer.write(chunk);
        if (mounted) setState(() => _answer = answer.toString());
      }
      if (mounted && _answer.trim().isEmpty) {
        setState(
          () => _error = 'The model returned an empty answer. Try again.',
        );
      }
    } catch (error, stackTrace) {
      if (mounted) setState(() => _error = 'The request failed. Try again.');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'builtin_ai_codelab',
          context: ErrorDescription('while generating an answer'),
        ),
      );
    } finally {
      if (session != null) {
        try {
          await session.close();
        } catch (error, stackTrace) {
          _reportCloseError(error, stackTrace, 'session');
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final model = _model;
    _model = null;
    if (model != null) {
      unawaited(
        model.close().catchError((Object error, StackTrace stackTrace) {
          _reportCloseError(error, stackTrace, 'model');
        }),
      );
    }
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _availability;
    final unsupported = BuiltInAiModels.forCurrentPlatform == null;
    final ready = status == BuiltInAiAvailability.available;
    final canPrepare = !unsupported && status?.isTransient == true;

    return Scaffold(
      appBar: AppBar(title: const Text('My first OS-model prompt')),
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
                            : _statusMessage(status),
                        key: const Key('status'),
                      ),
                      if (_preparing) ...[
                        const SizedBox(height: 12),
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
                      const SizedBox(height: 12),
                      if (canPrepare)
                        FilledButton(
                          onPressed: _preparing ? null : _prepare,
                          child: const Text(
                            'Prepare built-in AI (downloads may be several GB)',
                          ),
                        )
                      else if (_model == null && ready)
                        FilledButton(
                          onPressed: _busy ? null : _start,
                          child: const Text('Start built-in AI'),
                        )
                      else if (_model == null)
                        OutlinedButton(
                          onPressed: _busy ? null : _checkAvailability,
                          child: const Text('Check again'),
                        ),
                    ],
                  ),
                ),
              ),
              if (_model != null) ...[
                const SizedBox(height: 16),
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
              if (_error case final error?) ...[
                const SizedBox(height: 16),
                Text(error, key: const Key('error')),
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

void _reportCloseError(Object error, StackTrace stackTrace, String resource) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'builtin_ai_codelab',
      context: ErrorDescription('while closing the built-in AI $resource'),
    ),
  );
}
