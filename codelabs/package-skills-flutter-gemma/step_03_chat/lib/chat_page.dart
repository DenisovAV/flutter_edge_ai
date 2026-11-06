import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.model,
    required this.onModelRemoved,
  });

  final ModelChoice model;
  final VoidCallback onModelRemoved;

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

  Future<void> _send() async {
    final chat = _chat;
    final text = _input.text.trim();
    if (chat == null || text.isEmpty || _busy) return;

    setState(() {
      _turns
        ..add(_Turn(text, fromUser: true))
        ..add(const _Turn('', fromUser: false));
      _input.clear();
      _busy = true;
    });

    try {
      // isUser defaults to false. Without it the prompt is not a user turn and
      // the reply comes back empty, with no error.
      await chat.addQueryChunk(Message.text(text: text, isUser: true));
      final buffer = StringBuffer();
      await for (final chunk in chat.generateChatResponseAsync()) {
        if (chunk is TextResponse) {
          buffer.write(chunk.token);
          if (!mounted) return;
          setState(
            () => _turns[_turns.length - 1] = _Turn(
              buffer.toString(),
              fromUser: false,
            ),
          );
        }
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _turns[_turns.length - 1] = _Turn('⚠️ $error', fromUser: false),
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
                            ? 'Ask something'
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

class _Turn {
  const _Turn(this.text, {required this.fromUser});
  final String text;
  final bool fromUser;
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: turn.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: turn.fromUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(turn.text.isEmpty ? '…' : turn.text),
      ),
    );
  }
}
