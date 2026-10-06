import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';
import 'tools.dart';

/// What a line in the transcript is.
///
/// A chat with tools has four kinds of turn, not two, and showing only the
/// first and last of them is how a tool-calling app becomes impossible to
/// debug: the answer is right or wrong and nothing on screen says which
/// function produced it, with which arguments.
enum _TurnKind { user, model, toolCall, toolResult }

/// How many generations one message is allowed to cost.
///
/// The loop stops when a turn comes back with no calls in it — which is a
/// promise about the model, not about the code, and a model that keeps asking
/// would otherwise run until the context window filled. Four is enough for a
/// question that chains two or three calls and small enough that a stuck model
/// is over in seconds.
///
/// Below 1 is a `RangeError`, thrown on purpose: a cap of zero would answer
/// the message with nothing and close the stream, which looks exactly like a
/// model that had nothing to say.
const _maxToolTurns = 4;

/// The same chat as Step 2, with the loop handed to the SDK.
///
/// `generateChatResponseWithTools` is the loop from Step 2 written once, in
/// the package: generate, collect the calls, run them through the callback you
/// pass, feed each result back, generate again — until a turn has no calls in
/// it. What it adds is the three exits the hand-written version did not have:
/// a cancelled turn, a tool that throws, and a stream that errors mid-turn all
/// still answer every call that was committed to the history.
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
  Object? _loadError;

  /// A one-line problem that is not worth losing the chat over.
  String? _notice;

  /// Where the CURRENT generation is writing, and what it has written.
  ///
  /// One message can now produce several generations with tool calls between
  /// them, so "the reply" is no longer "the last bubble": running a tool
  /// appends two lines to the transcript and starts a fresh bubble underneath
  /// them. Holding the index is what keeps the reply below the work it did.
  final _reply = StringBuffer();
  int _replyAt = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // maxTokens is the CONTEXT WINDOW — prompt + history + reply share it.
      // It is NOT a reply-length cap; for that, pass maxOutputTokens below.
      // A driven loop spends more of it than Step 2's single round did: every
      // call and every tool response stays in the history for the rest of the
      // conversation.
      // maxTokens 1024 is what this checkpoint is built for; the example app
      // uses the same, and it is the value this was measured at.
      //
      // This checkpoint is asked to run on the CPU, and the reason is the
      // FILE, not the platform and not the model. The published artifact was
      // converted before litetune 0.1.4 began setting `prefer_activation_type=fp32`,
      // and without that key the GPU path answers every prompt with `<pad>` to
      // the token limit — measured on Android and on macOS Metal alike, with no
      // exception and no warning, a chat that looks alive and returns filler.
      //
      // Re-converted with a current litetune — which Step 4 does — the same
      // weights score identically on GPU and run about 1.5x faster. So this is
      // a workaround for one downloadable file, not a property of FunctionGemma.
      final inference = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.cpu,
      );
      // Hold the runtime before opening a chat on it: `createChat` can throw,
      // and a model this page never stored is a model `dispose` can never
      // close. A page that is already gone holds nothing, so it closes it here.
      if (!mounted) {
        await inference.close();
        return;
      }
      setState(() => _inference = inference);

      // Unchanged from Step 2. The declarations and the switch are properties
      // of the session; what changes below is only who drives the turns.
      final chat = await inference.createChat(
        modelType: widget.model.modelType,
        tools: const [multiplyTool],
        supportsFunctionCalls: true,
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

  /// One message, however many generations it takes.
  ///
  /// Compare with Step 2: there is no second `generateChatResponseAsync` here,
  /// no `addQueryChunk(Message.toolResponse(...))`, and no balancing of calls
  /// the app declined to run. All three are inside the stream below.
  Future<void> _send() async {
    final chat = _chat;
    final text = _input.text.trim();
    if (chat == null || text.isEmpty || _busy) return;

    setState(() {
      _turns
        ..add(_Turn(text, kind: _TurnKind.user))
        // The reply starts empty and grows as chunks arrive.
        ..add(const _Turn('', kind: _TurnKind.model));
      _replyAt = _turns.length - 1;
      _reply.clear();
      _input.clear();
      _notice = null;
      _busy = true;
    });

    var hitCap = false;
    try {
      // The staged user message is a PRECONDITION, exactly as it is for
      // `generateChatResponseAsync` — the loop drives generation, it does not
      // send your turn for you.
      await chat.addQueryChunk(Message.text(text: text, isUser: true));

      await for (final chunk in chat.generateChatResponseWithTools(
        // Run the function. Returning the map is what feeds the model; the
        // SDK wraps it in `Message.toolResponse` and stages it before the
        // next generation.
        onToolCall: _onToolCall,
        maxToolTurns: _maxToolTurns,
        // Called once, if the loop runs out of turns with calls still coming.
        // Without it the reply is quietly empty or half-written and nothing
        // says the cap is why.
        onMaxToolTurns: () => hitCap = true,
      )) {
        switch (chunk) {
          case TextResponse(:final token):
            // Each TextResponse carries only the NEW text, not the whole reply
            // so far — append, never replace.
            _reply.write(token);
            if (mounted) {
              setState(
                () => _turns[_replyAt] = _Turn(
                  _reply.toString(),
                  kind: _TurnKind.model,
                ),
              );
            }
          case ThinkingResponse():
            // Discarded upstream unless the chat was opened with
            // `enableThinking: true` — `complete` does exactly that.
            break;
          case FunctionCallResponse() || ParallelFunctionCallResponse():
            // Never arrives here: the loop consumes calls itself and passes
            // only text and thinking through. The branch keeps the switch
            // exhaustive over the sealed `ModelResponse`, so a case added to
            // the SDK fails to compile instead of being treated as silence.
            break;
        }
      }

      if (hitCap && mounted) {
        setState(
          () => _notice =
              'The model was still asking for tools after $_maxToolTurns '
              'turns, so the loop stopped. The answer above may be missing '
              'or cut short.',
        );
      }
    } catch (error) {
      // The half-written reply becomes the error, so the empty bubble never
      // just sits there. The SDK has already answered every call it committed
      // before rethrowing, so the chat is still usable for the next message.
      if (mounted) {
        setState(() {
          _reply.write('⚠️ $error');
          _turns[_replyAt] = _Turn(_reply.toString(), kind: _TurnKind.model);
        });
      }
    } finally {
      // `_busy` is what disables the composer, so clearing it belongs in
      // `finally` — a failed generation must not lock the app.
      if (mounted) {
        setState(() {
          // A last generation that produced no text — the cap was hit on a
          // call-only turn — leaves an empty bubble at the bottom.
          if (_reply.isEmpty &&
              _replyAt >= 0 &&
              _replyAt == _turns.length - 1) {
            _turns.removeAt(_replyAt);
          }
          _replyAt = -1;
          _busy = false;
        });
      }
    }
  }

  /// Runs one call and shows it. The return value is what the model sees.
  ///
  /// This callback is the whole of the app's half of the loop. Everything
  /// around it — collecting the calls, staging the responses, deciding whether
  /// to generate again — moved into the SDK.
  Future<Map<String, dynamic>> _onToolCall(FunctionCallResponse call) async {
    final result = _run(call);
    if (mounted) {
      setState(() {
        // A call-only generation wrote no text, and an empty bubble above the
        // call reads as a model that said nothing when in fact it asked.
        if (_reply.isEmpty && _replyAt >= 0 && _replyAt == _turns.length - 1) {
          _turns.removeAt(_replyAt);
        }
        _turns
          ..add(_Turn(_describeCall(call), kind: _TurnKind.toolCall))
          ..add(_Turn(jsonEncode(result), kind: _TurnKind.toolResult))
          // The next generation writes underneath the work it was given,
          // not above it.
          ..add(const _Turn('', kind: _TurnKind.model));
        _replyAt = _turns.length - 1;
        _reply.clear();
      });
    }
    return result;
  }

  /// Maps a call the model made onto the Dart that answers it.
  ///
  /// Keyed by name and with a real miss branch: the model writes the name, and
  /// a model can write a name you never declared. Returning an error map keeps
  /// the loop going — throwing here would end the turn, and the SDK would
  /// answer the committed call with `{'error': …}` and rethrow.
  Map<String, dynamic> _run(FunctionCallResponse call) => switch (call.name) {
    'multiply' => runMultiply(call.args),
    _ => {'error': 'This app has no tool named "${call.name}".'},
  };

  String _describeCall(FunctionCallResponse call) {
    final args = call.args.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(', ');
    return '${call.name}($args)';
  }

  /// Frees the disk. Close the runtime first — the file is mapped while a
  /// model is open, and deleting it underneath the engine is a crash waiting
  /// to happen.
  Future<void> _removeModel() async {
    try {
      await _inference?.close();
      // Inside `setState`: dropping the chat has to repaint, or the screen
      // keeps showing an enabled composer over a runtime that is gone.
      if (mounted) {
        setState(() {
          _inference = null;
          _chat = null;
        });
      }
      await FlutterEdgeAi.uninstallModel(widget.model.fileName);
      if (mounted) widget.onModelRemoved();
    } catch (error) {
      // Deleting can fail too — a missing install record, a file the OS still
      // holds. Show it the way a failed load is shown, and drop the chat with
      // it: a `close()` that threw leaves `_chat` non-null, and "The model did
      // not load." over a working composer is a lie.
      if (mounted) {
        setState(() {
          _chat = null;
          _loadError = error;
        });
      }
    }
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
    final theme = Theme.of(context);
    final ready = _chat != null;
    final error = _loadError;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.model.label),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '1 tool · ${multiplyTool.name} · up to $_maxToolTurns tool turns',
              style: theme.textTheme.labelSmall,
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Delete the downloaded model',
            // Not while the model is still opening: deleting the file
            // underneath an in-flight `getActiveModel()` is the crash the
            // comment on `_removeModel` warns about.
            onPressed: _busy || (!ready && error == null) ? null : _removeModel,
            icon: const Icon(Icons.delete_outline),
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
          if (_notice case final notice?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                notice,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
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
                            ? 'Try: 12 times 12, then that times 3'
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
  const _Turn(this.text, {required this.kind});

  final String text;
  final _TurnKind kind;
}

/// One line of the transcript, drawn so the four kinds are told apart at a
/// glance. The two middle ones are the point of this screen.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, colour) = switch (turn.kind) {
      _TurnKind.user => (null, scheme.primaryContainer),
      _TurnKind.model => (null, scheme.surfaceContainerHighest),
      _TurnKind.toolCall => ('the model asked for', scheme.tertiaryContainer),
      _TurnKind.toolResult => (
        'your function answered',
        scheme.secondaryContainer,
      ),
    };
    final mono =
        turn.kind == _TurnKind.toolCall || turn.kind == _TurnKind.toolResult;

    return Align(
      alignment: turn.kind == _TurnKind.user
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label != null) ...[
              Text(label, style: theme.textTheme.labelSmall),
              const SizedBox(height: 4),
            ],
            SelectableText(
              turn.text,
              style: mono
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
