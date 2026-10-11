import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:llamadart/llamadart.dart' as llama;

import 'model_import.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  edge.FlutterEdgeAi.logLevel = edge.EdgeAiLogLevel.none;
  llama.LlamaLogging.configure(level: llama.LlamaLogLevel.error);
  await edge.FlutterEdgeAi.initialize(
    inferenceEngines: const [LlamaEngineProvider()],
  );
  await restoreInstalledLlamaModel();
  runApp(
    MaterialApp(
      title: 'GGUF Lab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFB6E78C),
        scaffoldBackgroundColor: const Color(0xFF121817),
        useMaterial3: true,
      ),
      home: const _ChatPage(),
    ),
  );
}

class _ChatPage extends StatefulWidget {
  const _ChatPage();
  @override
  State<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<_ChatPage> with WidgetsBindingObserver {
  final _path = TextEditingController(
    text: const String.fromEnvironment('GGUF_MODEL_PATH'),
  );
  final _prompt = TextEditingController();
  final _scroll = ScrollController();
  final List<_Turn> _turns = [];
  edge.InferenceModel? _model;
  edge.InferenceChat? _chat;
  bool _loading = false;
  bool _generating = false;
  bool _stopped = false;
  Timer? _renderTimer;
  String _status = kIsWeb
      ? 'Enter a GGUF URL to begin.'
      : 'Load a local GGUF model to begin.';
  String _backend = 'Not loaded';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_resumeModel());
  }

  Future<void> _resumeModel() async {
    if (edge.FlutterEdgeAiPlugin.instance.modelManager.activeInferenceModel ==
        null) {
      return;
    }
    setState(() {
      _loading = true;
      _status = 'Restoring the installed model…';
    });
    try {
      final loaded = await edge.FlutterEdgeAi.getActiveModel(maxTokens: 2048);
      if (!mounted) {
        await loaded.close();
        return;
      }
      _model = loaded;
      await _newChat();
      if (mounted) {
        setState(() {
          _path.text = edge
              .FlutterEdgeAiPlugin
              .instance
              .modelManager
              .activeInferenceModel!
              .name;
          _backend = loaded.activeBackend?.name.toUpperCase() ?? 'UNKNOWN';
          _status = 'Installed model restored. Start a new conversation.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not restore the model: $error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_stop());
    }
  }

  Future<void> _chooseModel() async {
    if (_loading || _generating) return;
    if (kIsWeb) {
      await _load();
      return;
    }
    setState(() => _loading = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'GGUF models', extensions: ['gguf']),
        ],
      );
      if (file == null || !mounted) return;
      setState(() => _status = 'Importing model into app storage…');
      final imported = await importModel(file.path);
      if (!mounted) return;
      _path.text = imported;
      await _load();
    } catch (error) {
      if (mounted) setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _clearTurns() {
    for (final turn in _turns) {
      turn.dispose();
    }
    _turns.clear();
  }

  Future<void> _load() async {
    if (_path.text.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _chat = null;
      _status = 'Loading model…';
      _backend = 'Not loaded';
      _clearTurns();
    });
    try {
      await _model?.close();
      _model = null;
      final installation = edge.FlutterEdgeAi.installModel(
        modelType: edge.ModelType.general,
        fileType: edge.ModelFileType.binary,
      );
      if (kIsWeb) {
        await installation.fromNetwork(_path.text.trim()).install();
      } else {
        await installation.fromFile(_path.text.trim()).install();
      }
      final loaded = await edge.FlutterEdgeAi.getActiveModel(maxTokens: 2048);
      if (!mounted) {
        await loaded.close();
        return;
      }
      _model = loaded;
      await _newChat();
      if (mounted) {
        setState(() {
          _backend = _model!.activeBackend?.name.toUpperCase() ?? 'UNKNOWN';
          _status = 'Ready · 2,048 context tokens · 128 output tokens';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _newChat() async {
    final chat = await _model!.createChat(
      systemInstruction: 'You are a helpful assistant. Keep answers concise.',
      modelType: edge.ModelType.general,
      temperature: .7,
      topK: 40,
      topP: .9,
      maxOutputTokens: 128,
    );
    if (!mounted) {
      await chat.close();
      return;
    }
    _chat = chat;
    if (mounted) {
      setState(() {
        _clearTurns();
        _status = 'New conversation ready.';
      });
    }
  }

  Future<void> _send() async {
    final input = _prompt.text.trim();
    final chat = _chat;
    if (input.isEmpty || chat == null || _generating || _loading) return;
    final reply = _Turn(false, '');
    setState(() {
      _generating = true;
      _stopped = false;
      _status = 'Generating locally…';
      _turns.addAll([_Turn(true, input), reply]);
      _prompt.clear();
    });
    try {
      await chat.addQueryChunk(edge.Message.text(text: input, isUser: true));
      await for (final response in chat.generateChatResponseAsync()) {
        if (!mounted) break;
        if (response is edge.TextResponse) {
          reply.append(response.token);
          _renderTimer ??= Timer(const Duration(milliseconds: 33), () {
            _renderTimer = null;
            if (!mounted) return;
            final follow =
                !_scroll.hasClients || _scroll.position.extentAfter < 120;
            reply.flush();
            if (follow) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _scroll.hasClients) {
                  _scroll.jumpTo(_scroll.position.maxScrollExtent);
                }
              });
            }
          });
        }
      }
      final metrics = chat.session.getSessionMetrics();
      if (mounted) {
        setState(() {
          _status = _stopped
              ? 'Stopped. The interrupted turn was discarded; you can continue.'
              : '${metrics.inputTokens} input · ${metrics.outputTokens > 0 ? '${metrics.outputTokens} output tokens' : 'output count unavailable'}'
                    '${(chat.session as LlamaInferenceSession).lastFinishReason == 'length' ? ' · Output limit reached' : ''}';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = '$error The failed turn was discarded.';
        });
      }
    } finally {
      _renderTimer?.cancel();
      _renderTimer = null;
      if (mounted) {
        reply.flush();
        setState(() {
          if (!(chat.session as LlamaInferenceSession).lastTurnCommitted) {
            _turns.remove(reply);
            reply.dispose();
            if (_turns.isNotEmpty && _turns.last.isUser) {
              _turns.removeLast().dispose();
            }
          }
          _generating = false;
        });
      }
    }
  }

  Future<void> _stop() async {
    _stopped = true;
    await _chat?.session.stopGeneration();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _renderTimer?.cancel();
    _clearTurns();
    unawaited(_model?.close());
    _path.dispose();
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Padding(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 520 ? 12 : 28,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (MediaQuery.viewInsetsOf(context).bottom == 0) ...[
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.memory,
                            color: Color(0xFFB6E78C),
                            size: 32,
                          ),
                          SizedBox(width: 12),
                          Text(
                            'GGUF Lab',
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      Chip(label: Text(_backend)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Flutter Edge AI × llamadart',
                    style: TextStyle(color: Color(0xFFA5B9B0), fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final field = TextField(
                        controller: _path,
                        readOnly: !kIsWeb,
                        decoration: const InputDecoration(
                          labelText: kIsWeb
                              ? 'GGUF model URL'
                              : 'Local GGUF model',
                          border: OutlineInputBorder(),
                        ),
                      );
                      final button = FilledButton(
                        onPressed: _loading || _generating
                            ? null
                            : _chooseModel,
                        child: Text(
                          _loading
                              ? 'Loading…'
                              : kIsWeb
                              ? 'Load URL'
                              : 'Choose model',
                        ),
                      );
                      if (constraints.maxWidth < 520) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [field, const SizedBox(height: 8), button],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: field),
                          const SizedBox(width: 12),
                          button,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _status,
                          style: const TextStyle(color: Color(0xFFA5B9B0)),
                        ),
                      ),
                      TextButton(
                        onPressed: _model == null || _generating || _loading
                            ? null
                            : _newChat,
                        child: const Text('New chat'),
                      ),
                    ],
                  ),
                ],
                const Divider(height: 28),
                Expanded(
                  child: _turns.isEmpty
                      ? const Center(
                          child: Text(
                            'Your model. Your device.\nStart a conversation below.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 22,
                              color: Color(0xFFA5B9B0),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: _turns.length,
                          itemBuilder: (context, index) {
                            final turn = _turns[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: turn.isUser
                                      ? const Color(0xFF253A31)
                                      : const Color(0xFF1B2621),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        turn.isUser ? 'YOU' : 'LOCAL MODEL',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          letterSpacing: 1.5,
                                          color: Color(0xFFB6E78C),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ValueListenableBuilder<String>(
                                        valueListenable: turn.text,
                                        builder: (_, text, _) => SelectableText(
                                          text.isEmpty ? '…' : text,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            height: 1.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _prompt,
                        enabled: _chat != null && !_generating,
                        decoration: const InputDecoration(
                          hintText: 'Ask your local model…',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: _generating
                          ? _stop
                          : _chat == null
                          ? null
                          : _send,
                      child: Text(_generating ? 'Stop' : 'Send'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Turn {
  _Turn(this.isUser, String initial) : text = ValueNotifier(initial);
  final bool isUser;
  final ValueNotifier<String> text;
  final StringBuffer _buffer = StringBuffer();

  void append(String token) => _buffer.write(token);
  void flush() => text.value = _buffer.toString();
  void dispose() => text.dispose();
}
