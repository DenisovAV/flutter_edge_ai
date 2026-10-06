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

/// A chat where the model can ask the app to run a function.
///
/// The loop is written out by hand here — generate, see a call, run it, send
/// the result back, generate again — because that is the thing worth seeing
/// once. Step 3 replaces all of it with one SDK call.
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // maxTokens is the CONTEXT WINDOW — prompt + history + reply share it.
      // It is NOT a reply-length cap; for that, pass maxOutputTokens below.
      // Tools are not free inside it: the declarations below are rendered into
      // the prompt once and stay in the history for the rest of the
      // conversation, and every call and every tool response is another turn in
      // the same window — so a tool-calling chat runs out of room sooner than a
      // plain one does.
      //
      // Note what this call does NOT take: `tools`. There is no modality flag
      // to set in two places here — `getActiveModel` builds the engine, and
      // nothing about the weights changes when you declare a function. Tools
      // belong to the SESSION, and the session is opened one call down.
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

      final chat = await inference.createChat(
        // Which family's call syntax to speak. For FunctionGemma on a
        // `.litertlm`, the declarations go to LiteRT-LM, which renders them
        // into the developer turn these weights were trained on, hands the
        // call back as structured `tool_calls`, and takes your result as a
        // role-`tool` message that continues the same model turn.
        modelType: widget.model.modelType,
        // The declarations. This is the whole of "the model can call your
        // code": a list of names, descriptions and argument schemas.
        tools: const [multiplyTool],
        // And the switch that turns the machinery on. `tools` without this is
        // the quiet failure worth knowing about: `InferenceChat` logs
        // "Model does not support function calls, but tools were provided.
        // Tools will be ignored", never renders the declarations, and the
        // model answers every question out of its own head — fluently, and
        // with arithmetic it made up.
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

  /// The loop, by hand.
  ///
  /// Read it as three questions asked in order: what does the model say, does
  /// it want a function run, and what does it say once it has the answer.
  Future<void> _send() async {
    final chat = _chat;
    final text = _input.text.trim();
    if (chat == null || text.isEmpty || _busy) return;

    setState(() {
      _turns.add(_Turn(text, kind: _TurnKind.user));
      _input.clear();
      _notice = null;
      _busy = true;
    });

    try {
      await chat.addQueryChunk(Message.text(text: text, isUser: true));

      // ROUND ONE. The model either answers, or asks for the function.
      final calls = await _generate(chat);
      if (calls.isEmpty) return; // a plain answer — nothing to run

      // The app runs it. This half is never the SDK's: a tool is an action in
      // your program, and only your program knows what `multiply` means.
      for (final call in calls) {
        final result = _run(call);
        if (mounted) {
          setState(() {
            _turns
              ..add(_Turn(_describeCall(call), kind: _TurnKind.toolCall))
              ..add(_Turn(jsonEncode(result), kind: _TurnKind.toolResult));
          });
        }
        // Handing the answer back is a MESSAGE, not a return value. Until this
        // reaches the session the model has not seen the number at all.
        await chat.addQueryChunk(
          Message.toolResponse(toolName: call.name, response: result),
        );
      }

      // ROUND TWO. Same session, same history — now with the result in it.
      final again = await _generate(chat);
      if (again.isEmpty) return;

      // The model asked for another call. Every call the stream yielded is
      // ALREADY in the chat's history, and a call left without a response
      // poisons the next turn on this chat — the model re-issues it, or
      // answers nothing at all. So the ones this step will not run still get
      // an answer, and it says what happened.
      for (final call in again) {
        if (mounted) {
          setState(
            () => _turns.add(
              _Turn(_describeCall(call), kind: _TurnKind.toolCall),
            ),
          );
        }
        await chat.addQueryChunk(
          Message.toolResponse(
            toolName: call.name,
            response: const {
              'status': 'not run — this app runs one round of tool calls',
            },
          ),
        );
      }
      if (mounted) {
        setState(
          () => _notice =
              'The model asked for another call. This hand-written loop runs '
              'one round and stops. Step 3 hands the loop to the SDK, which '
              'keeps going up to a limit you set.',
        );
      }
    } catch (error) {
      // The half-written reply becomes the error, so the bubble `_generate`
      // opened never just sits there empty. A failure between generations —
      // staging the tool response, say — has no bubble to overwrite, and gets
      // its own.
      //
      // What this does NOT do is balance the history, and that is the hole in
      // the hand-written loop. If `generateChatResponseAsync` throws
      // mid-stream, the calls it had already yielded are committed and now
      // have no response — exactly the dangling state the round-two branch
      // above takes such care to avoid. Closing it means tracking what
      // `_generate` collected before it threw and answering those calls here.
      // Step 3 hands the loop to the SDK, which already does.
      if (mounted) {
        setState(() {
          final at = _turns.length - 1;
          if (at >= 0 && _turns[at].kind == _TurnKind.model) {
            _turns[at] = _Turn('⚠️ $error', kind: _TurnKind.model);
          } else {
            _turns.add(_Turn('⚠️ $error', kind: _TurnKind.model));
          }
        });
      }
    } finally {
      // `_busy` is what disables the composer, so clearing it belongs in
      // `finally` — a failed generation must not lock the app.
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Streams ONE generation into a fresh bubble and collects any calls it made.
  ///
  /// The text and the calls arrive on the same stream: `ModelResponse` is a
  /// sealed type, and a turn is a mixture of its cases rather than one or the
  /// other. Switching over it exhaustively is what stops a future case from
  /// being silently treated as text.
  Future<List<FunctionCallResponse>> _generate(InferenceChat chat) async {
    final pending = <FunctionCallResponse>[];
    final buffer = StringBuffer();

    // Guarded like every other `setState` in this file: `_generate` is called
    // after an `await`, so the page can be gone by the time it runs. With no
    // page there is nothing to paint into, and the two writes to `at` below
    // are guarded the same way.
    if (mounted) {
      setState(() => _turns.add(const _Turn('', kind: _TurnKind.model)));
    }
    final at = _turns.length - 1;

    await for (final chunk in chat.generateChatResponseAsync()) {
      switch (chunk) {
        case TextResponse(:final token):
          // Each TextResponse carries only the NEW text, not the whole reply
          // so far — append, never replace.
          buffer.write(token);
          // Guarded rather than returned: a call this stream has already
          // yielded is committed to the chat's history and still has to be
          // answered, so the loop keeps draining even with no screen to paint.
          if (mounted) {
            setState(
              () =>
                  _turns[at] = _Turn(buffer.toString(), kind: _TurnKind.model),
            );
          }
        case FunctionCallResponse():
          pending.add(chunk);
        case ParallelFunctionCallResponse(:final calls):
          // One turn, several calls. FunctionGemma with a single declared tool
          // will rarely do this, but the case exists and dropping it would
          // leave committed calls unanswered.
          pending.addAll(calls);
        case ThinkingResponse():
          // Filtered out upstream unless the chat was opened with
          // `enableThinking: true` — `complete` does exactly that. Here the branch
          // exists so the switch stays exhaustive.
          break;
      }
    }

    // A call-only turn generates no text, and an empty bubble under it reads
    // as a model that said nothing when in fact it asked a question.
    if (buffer.isEmpty && mounted) {
      setState(() => _turns.removeAt(at));
    }
    return pending;
  }

  /// Maps a call the model made onto the Dart that answers it.
  ///
  /// Keyed by name and with a real miss branch: the model writes the name, and
  /// a model can write a name you never declared. That is a turn to answer,
  /// not a crash.
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
              '1 tool · ${multiplyTool.name}',
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
                            ? 'Try: what is 1234 times 5678?'
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
