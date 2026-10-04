import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'color_tool.dart';
import 'model.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.model,
    required this.onModelRemoved,
    required this.onColor,
  });

  final ModelChoice model;
  final VoidCallback onModelRemoved;
  final ValueChanged<Color> onColor;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _turns = <_Turn>[];
  InferenceModel? _inference;
  InferenceChat? _chat;
  bool _busy = false;
  Object? _loadError;

  /// Where the reply being streamed sits in [_turns]. Tool notes are inserted
  /// before it, so it moves.
  int _replyAt = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // maxTokens is the whole context window — prompt, history and reply —
      // not the reply length. The reply is capped by maxOutputTokens below.
      final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      if (!mounted) {
        await inference.close();
        return;
      }
      setState(() => _inference = inference);
      final chat = await inference.createChat(
        // Without supportsFunctionCalls no call is parsed, and on Gemma 4 the
        // model's raw tool-call JSON lands in the reply text instead.
        tools: const [ColorTool.declaration],
        supportsFunctionCalls: true,
        // Required on the web; native builds fall back to the installed type.
        modelType: widget.model.modelType,
        maxOutputTokens: 256,
      );
      if (!mounted) {
        await chat.close();
        return;
      }
      setState(() => _chat = chat);
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  Map<String, dynamic> _runTool(FunctionCallResponse call) {
    final outcome = ColorTool.run(call.name, call.args);
    final color = outcome.color;
    if (color != null) widget.onColor(color);
    _insertNote('🔧 ${call.name}(${call.args}) → ${outcome.result}');
    return outcome.result;
  }

  void _insertNote(String text) {
    if (!mounted) return;
    setState(() {
      _turns.insert(_replyAt, _Turn(text, kind: _Kind.tool));
      _replyAt++;
    });
  }

  Future<void> _send() async {
    final chat = _chat;
    final text = _input.text.trim();
    if (chat == null || text.isEmpty || _busy) return;

    setState(() {
      _turns.add(_Turn(text, kind: _Kind.user));
      _replyAt = _turns.length;
      _turns.add(const _Turn('', kind: _Kind.model));
      _input.clear();
      _busy = true;
    });

    try {
      // isUser defaults to false. Without it the prompt is not a user turn and
      // the reply comes back empty, with no error.
      await chat.addQueryChunk(Message.text(text: text, isUser: true));
      final buffer = StringBuffer();
      // Calls the tool for each function call, feeds the result back, and
      // continues until the model answers in text.
      await for (final chunk in chat.generateChatResponseWithTools(
        onToolCall: _runTool,
        // Reaching the limit ends the stream without an error; this callback
        // is the only signal.
        onMaxToolTurns: () => _insertNote('Stopped after 8 tool calls.'),
      )) {
        if (chunk is TextResponse) {
          buffer.write(chunk.token);
          if (!mounted) return;
          setState(
            () =>
                _turns[_replyAt] = _Turn(buffer.toString(), kind: _Kind.model),
          );
        }
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _turns[_replyAt] = _Turn('⚠️ $error', kind: _Kind.model),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeModel() async {
    try {
      await _inference?.close();
      if (mounted) {
        setState(() {
          _inference = null;
          _chat = null;
        });
      }
      await FlutterEdgeAi.uninstallModel(widget.model.fileName);
      if (mounted) widget.onModelRemoved();
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  @override
  void dispose() {
    // A model holds native memory. dispose cannot await, so the future is
    // dropped on purpose and its error caught.
    _inference?.close().catchError((Object _) {});
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _chat != null;
    final error = _loadError;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.model.label),
        actions: [
          IconButton(
            tooltip: 'Delete the downloaded model',
            onPressed: _busy || (!ready && error == null) ? null : _removeModel,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'The model did not load.\n$error',
                textAlign: TextAlign.center,
              ),
            )
          else if (!ready)
            const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _turns.length,
              itemBuilder: (context, i) => _Bubble(turn: _turns[i]),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: ready && !_busy,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: ready
                            ? 'Try: make the app green'
                            : 'Loading the model…',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: ready && !_busy ? _send : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Kind { user, model, tool }

class _Turn {
  const _Turn(this.text, {required this.kind});
  final String text;
  final _Kind kind;
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (turn.kind == _Kind.tool) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          turn.text,
          style: TextStyle(color: scheme.outline, fontSize: 12),
        ),
      );
    }
    final fromUser = turn.kind == _Kind.user;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: fromUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(turn.text.isEmpty ? '…' : turn.text),
      ),
    );
  }
}
