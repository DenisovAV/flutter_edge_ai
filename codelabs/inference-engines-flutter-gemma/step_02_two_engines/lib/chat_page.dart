import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';

/// A chat that shows the reply as it is generated.
///
/// `generateChatResponseAsync` emits one [ModelResponse] per decoded chunk,
/// so the first words appear long before the last one is computed.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.model,
    required this.onSwitch,
    required this.onModelRemoved,
  });

  final ModelChoice model;

  /// Asks the app to run a different model — possibly on a different engine.
  final ValueChanged<ModelChoice> onSwitch;

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
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // maxTokens is the CONTEXT WINDOW — prompt + history + reply share it.
      // It is NOT a reply-length cap; for that, pass maxOutputTokens below.
      final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
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
        maxOutputTokens: 256,
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

  /// The models this app can offer that it is not already running.
  ///
  /// `Models.builtIn` throws where this app has no built-in arm, and this
  /// getter runs inside `itemBuilder` — a throw during a build is a red screen,
  /// not something a `catch` around the tap could reach. So ask here and drop
  /// the entry instead. The sample gives Windows no built-in entry, and Linux
  /// has no OS model at all.
  List<ModelChoice> get _alternatives {
    final all = <ModelChoice>[...Models.downloadable];
    try {
      all.add(Models.builtIn);
    } on UnsupportedError {
      // No built-in model on this platform — offer the downloadable ones only.
    }
    return all.where((m) => m.id != widget.model.id).toList();
  }

  Future<void> _onAction(_Action action) async {
    try {
      switch (action) {
        case _Switch(:final model):
          await _switchTo(model);
        case _Remove():
          await _removeModel();
      }
    } catch (error) {
      // Closing a runtime and deleting a file can both fail. Surface it the way
      // a failed load is surfaced, and drop the chat with it: a `close()` that
      // threw leaves `_chat` non-null, and "The model did not load." over an
      // enabled composer is a lie.
      if (mounted) {
        setState(() {
          _chat = null;
          _loadError = error;
        });
      }
    }
  }

  /// Release this engine's runtime before the app activates another model.
  Future<void> _switchTo(ModelChoice next) async {
    await _inference?.close();
    // Inside `setState`: dropping the chat has to repaint, or the screen keeps
    // showing an enabled composer over a runtime that is gone.
    if (mounted) {
      setState(() {
        _inference = null;
        _chat = null;
      });
      widget.onSwitch(next);
    }
  }

  /// Frees the disk. Close the runtime first — the file is mapped while a
  /// model is open, and deleting it underneath the engine is a crash waiting
  /// to happen.
  Future<void> _removeModel() async {
    await _inference?.close();
    if (mounted) {
      setState(() {
        _inference = null;
        _chat = null;
      });
    }
    await FlutterEdgeAi.uninstallModel(widget.model.id);
    if (mounted) widget.onModelRemoved();
  }

  @override
  void dispose() {
    // Sessions and models hold native memory — always close them. `dispose`
    // cannot await, so the future is dropped on purpose, and caught so a
    // failing native teardown does not escape as an unhandled async error.
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
        // The engine is visible on purpose — it is the thing this codelab
        // switches, and nothing in the chat below changes when it does.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              widget.model.isBuiltIn
                  ? 'engine: built-in OS model'
                  : 'engine: LiteRT-LM',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
        actions: [
          PopupMenuButton<_Action>(
            // Not while the model is still opening: switching or deleting
            // underneath an in-flight `getActiveModel()` is the crash the
            // comment on `_removeModel` warns about.
            enabled: !_busy && (ready || error != null),
            onSelected: _onAction,
            itemBuilder: (context) => [
              for (final m in _alternatives)
                PopupMenuItem(value: _Switch(m), child: Text('Use ${m.label}')),
              // Only a downloaded model can be forgotten. A built-in one has
              // no file to free and no install record to remove, so offering
              // it would be a lie — `uninstallModel` would throw.
              if (!widget.model.isBuiltIn) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: _Remove(),
                  child: Text('Forget this model'),
                ),
              ],
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (error != null)
            _LoadFailed(error: error, onRetry: _retryLoad)
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
                            : error != null
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

/// Shown in place of the loading bar when the model could not be opened.
class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text('The model did not load.\n$error', textAlign: TextAlign.center),
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

sealed class _Action {
  const _Action();
}

final class _Switch extends _Action {
  const _Switch(this.model);
  final ModelChoice model;
}

final class _Remove extends _Action {
  const _Remove();
}
