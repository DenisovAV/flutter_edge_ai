import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';

/// A plain chat: the model, and nothing it can do besides talk.
///
/// `generateChatResponseAsync` emits one [ModelResponse] per decoded chunk,
/// so the first words appear long before the last one is computed. Ask it
/// what time it is, or to put a meeting in your calendar: it will answer,
/// confidently, and nothing will happen. Step 2 replaces this page with an
/// agent.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.model,
    required this.onModelRemoved,
  });

  final ModelChoice model;

  /// Lets the gate send the app back to the download screen.
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
  bool _removing = false;
  Object? _loadError;
  Object? _removeError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // maxTokens is the CONTEXT WINDOW — prompt + history + reply share it.
      // It is NOT a reply-length cap; for that, pass maxOutputTokens below.
      // 4096 leaves room for what an agent adds from Step 2 on: a list of
      // skills in the system prompt, a skill's instructions, tool results.
      final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
      // Hold the runtime before opening a chat on it: `createChat` can throw,
      // and a model this page never stored is a model `dispose` can never
      // close. A page that is already gone holds nothing, so it closes it here.
      if (!mounted) {
        await inference.close();
        return;
      }
      setState(() => _inference = inference);

      final chat = await inference.createChat(
        modelType: widget.model.modelType,
        maxOutputTokens: 512,
      );
      // The same guard, one call later and for the same reason: a chat this
      // page never stored is a native session `dispose` can never close.
      if (!mounted) {
        await chat.close();
        return;
      }
      setState(() => _chat = chat);
    } catch (error) {
      // Loading is the likeliest thing to fail on a real device: a forgotten
      // engine package, too little memory, a half-written model file. Show it
      // instead of sitting on the progress bar forever.
      if (mounted) setState(() => _loadError = error);
    }
  }

  void _retryLoad() {
    setState(() => _loadError = null);
    _load();
  }

  Future<void> _send() async {
    final chat = _chat;
    final text = _input.text.trim();
    if (chat == null || text.isEmpty || _busy) return;

    setState(() {
      _turns
        ..add(_Turn(text, fromUser: true))
        // The reply starts empty and grows as chunks arrive.
        ..add(_Turn('', fromUser: false));
      _input.clear();
      _busy = true;
    });

    try {
      await chat.addQueryChunk(Message.text(text: text, isUser: true));

      final buffer = StringBuffer();
      await for (final chunk in chat.generateChatResponseAsync()) {
        // Each TextResponse carries only the NEW text, not the whole reply
        // so far — append, never replace.
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
      // The half-written reply becomes the error, so the empty bubble never
      // just sits there. The chat's own history now holds a user turn the model
      // never answered; a production app would reset it with `clearHistory`.
      if (mounted) {
        setState(
          () => _turns[_turns.length - 1] = _Turn('⚠️ $error', fromUser: false),
        );
      }
    } finally {
      // `_busy` is what disables the composer, so clearing it belongs in
      // `finally` — a failed generation must not lock the app.
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Frees the disk. Takes the runtime off the page first, so nothing can
  /// send to it — or delete twice — while it closes; then closes it, since the
  /// file is mapped while a model is open, and deleting it underneath the
  /// engine is a crash waiting to happen. Closing the model closes its chat.
  Future<void> _removeModel() async {
    final inference = _inference;
    setState(() {
      _removing = true;
      _inference = null;
      _chat = null;
      _loadError = null;
      _removeError = null;
    });
    try {
      await inference?.close();
      await FlutterEdgeAi.uninstallModel(widget.model.fileName);
      if (mounted) widget.onModelRemoved();
    } catch (error) {
      // Deleting can fail too — a missing install record, a file the OS still
      // holds. Say so, and offer the delete again, not a reload.
      if (mounted) {
        setState(() {
          _removing = false;
          _removeError = error;
        });
      }
    }
  }

  @override
  void dispose() {
    // Sessions and models hold native memory — always close them. `dispose`
    // cannot await, so the close runs on its own, and a failure is reported
    // rather than dropped: a model that did not close may still hold memory.
    _inference?.close().catchError(_reportCloseError);
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _chat != null;
    final error = _loadError;
    final removeError = _removeError;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.model.label),
        actions: [
          IconButton(
            tooltip: 'Delete the downloaded model',
            // Not while the model is still opening: deleting the file
            // underneath an in-flight `getActiveModel()` is the crash the
            // comment on `_removeModel` warns about.
            onPressed: _busy || _removing || (!ready && error == null)
                ? null
                : _removeModel,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          if (removeError != null)
            _Failed(
              title: 'The model was not deleted.',
              error: removeError,
              onRetry: _removeModel,
            )
          else if (error != null)
            _Failed(
              title: 'The model did not load.',
              error: error,
              onRetry: _retryLoad,
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
                            : error != null || removeError != null
                            ? 'No model loaded'
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

/// Reports a close that failed in `dispose`, where nothing can await it.
void _reportCloseError(Object error, StackTrace stack) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'on_device_agent',
      context: ErrorDescription('while closing the model'),
    ),
  );
}

/// Shown in place of the loading bar when loading or deleting the model
/// failed, with a button that tries that again.
class _Failed extends StatelessWidget {
  const _Failed({
    required this.title,
    required this.error,
    required this.onRetry,
  });

  final String title;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text('$title\n$error', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
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
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(turn.text),
      ),
    );
  }
}
