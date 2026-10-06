import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'model.dart';
import 'tools.dart';

/// What a line in the transcript is.
///
/// A chat with tools has five kinds of turn, not two. Showing only the first
/// and the last of them is how a tool-calling app becomes impossible to debug:
/// the answer is right or wrong and nothing on screen says which function
/// produced it, with which arguments, or what the model was thinking when it
/// chose.
enum _TurnKind { user, thinking, model, toolCall, toolResult }

/// How many generations one message is allowed to cost.
///
/// The loop stops when a turn comes back with no calls in it — a promise about
/// the model, not about the code — so a model that keeps asking would
/// otherwise run until the context window filled. Six is enough for a question
/// that chains three calls and small enough that a stuck model is over in
/// seconds. Below 1 is a `RangeError`, thrown on purpose: a cap of zero would
/// answer the message with nothing and close the stream, which looks exactly
/// like a model that had nothing to say.
const _maxToolTurns = 6;

/// The finished app: four tools, a loop the SDK drives, and two session
/// settings you can change while it is running.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.model,
    required this.onModelRemoved,
  });

  final ModelChoice model;

  /// Lets the gate send the app back to the model list.
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
  String? _notice;

  /// Set by a tool, not by the UI. This is the whole visible half of
  /// `change_background_color`: the model picks a name, the runner answers with
  /// it, and the page reads that same answer.
  Color? _background;

  /// Both of these are SESSION settings, fixed for a chat's lifetime — which
  /// is why changing either one closes the chat and opens a new one, and why
  /// the transcript goes with it.
  ToolChoice _toolChoice = ToolChoice.auto;
  late bool _thinking = widget.model.supportsThinking;

  /// Where the CURRENT generation is writing, and what it has written.
  ///
  /// One message can produce several generations with tool calls between them,
  /// so "the reply" is not "the last bubble": running a tool appends two lines
  /// and starts a fresh bubble underneath them. Thinking gets its own index
  /// because it arrives interleaved with the text and belongs above it.
  final _reply = StringBuffer();
  final _thought = StringBuffer();
  int _replyAt = -1;
  int _thinkAt = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // maxTokens is the CONTEXT WINDOW — prompt + history + reply share it.
      // It is NOT a reply-length cap; for that, pass maxOutputTokens below.
      // Four declarations, every call and every tool response all live in
      // this budget for the rest of the conversation, and thinking is spent
      // out of it too.
      //
      // Note what this call does NOT take: `tools`. Unlike the modality flags
      // of the multimodal codelab there is nothing to set in two places —
      // `getActiveModel` builds the engine, and nothing about the weights
      // changes when you declare a function.
      //
      // Both arguments come from the model, not from this page: FunctionGemma's
      // download needs 1024 and the CPU, exactly as in Steps 1–3, while Gemma 4
      // and a model you converted yourself get 4096 and the engine's default.
      final inference = await FlutterEdgeAi.getActiveModel(
        maxTokens: widget.model.maxTokens,
        preferredBackend: widget.model.preferredBackend,
      );
      // Hold the runtime before opening a chat on it: `createChat` can throw,
      // and a model this page never stored is a model `dispose` can never
      // close. A page that is already gone holds nothing, so it closes it here.
      if (!mounted) {
        await inference.close();
        return;
      }
      setState(() => _inference = inference);

      final chat = await _openChat(inference);
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

  /// The session, with everything that is per-session on it.
  Future<InferenceChat> _openChat(InferenceModel inference) =>
      inference.createChat(
        // Which family's call syntax the SDK writes and reads.
        modelType: widget.model.modelType,
        // Four declarations now instead of one. Nothing else in this file
        // changed to add the other three: the loop dispatches by name.
        tools: toolbox,
        supportsFunctionCalls: true,
        // Whether the model may, must, or must not call. On a `.litertlm` the
        // runtime holds the declarations for both families — `createChat`
        // forwards `tools` to `createSession` without consulting this — so
        // `none` cannot take them back out. What it switches off is the SDK's
        // suppression of tool-call JSON, which is why a call made under `none`
        // can arrive as raw markup in the bubble. On a `.task` FunctionGemma
        // the SDK writes the declarations into the prompt itself, and there
        // `none` really does leave them out.
        toolChoice: _toolChoice,
        // Reason first, then answer. On weights with no thinking training this
        // buys nothing, which is why the switch is disabled for those.
        enableThinking: _thinking,
        // Thinking is generated text and comes out of the same budget as the
        // answer, so a reasoning turn needs more room than a plain one.
        maxOutputTokens: _thinking ? 512 : 256,
      );

  void _retryLoad() {
    setState(() => _loadError = null);
    _load();
  }

  /// Rebuilds the session because a session setting changed.
  ///
  /// There is no way to change `toolChoice` or `enableThinking` on a live chat:
  /// both are decided when the session is created — one travels with the
  /// declarations the session is opened with, the other switches on a
  /// generation channel — so the honest thing is to close this one and open
  /// another. The
  /// transcript goes with it, because the new session's history is empty and a
  /// transcript that survived would be describing a conversation the model can
  /// no longer remember.
  Future<void> _reopenChat({ToolChoice? choice, bool? thinking}) async {
    final inference = _inference;
    final old = _chat;
    if (inference == null || _busy) return;

    setState(() {
      if (choice != null) _toolChoice = choice;
      if (thinking != null) _thinking = thinking;
      _chat = null; // disables the composer while the session is rebuilt
      _turns.clear();
      _notice =
          _toolChoice == ToolChoice.required &&
              !widget.model.supportsRequiredToolChoice
          ? '${widget.model.label} cannot be forced to call a tool — nothing '
                'in the prompt it is given can say "you must", so `required` '
                'behaves as "auto".'
          : null;
    });

    try {
      await old?.close();
      final chat = await _openChat(inference);
      if (!mounted) {
        await chat.close();
        return;
      }
      setState(() => _chat = chat);
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  /// One message, however many generations it takes.
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
      _thinkAt = -1;
      _reply.clear();
      _thought.clear();
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
          case ThinkingResponse(:final content):
            // These reach the stream only because the chat was opened with
            // `enableThinking: true`; with it false the SDK drops them before this
            // loop ever sees one.
            _thought.write(content);
            if (mounted) setState(_paintThinking);
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
          _dropEmptyReply();
          _replyAt = -1;
          _thinkAt = -1;
          _busy = false;
        });
      }
    }
  }

  /// Puts the thinking above the answer it led to.
  ///
  /// The first thinking chunk of a generation inserts a bubble in front of the
  /// reply rather than appending one, because the model reasons before it
  /// speaks and a transcript that shows it afterwards reads backwards.
  void _paintThinking() {
    if (_thinkAt < 0) {
      _turns.insert(_replyAt, const _Turn('', kind: _TurnKind.thinking));
      _thinkAt = _replyAt;
      _replyAt += 1;
    }
    _turns[_thinkAt] = _Turn(_thought.toString(), kind: _TurnKind.thinking);
  }

  /// Removes the reply bubble if this generation never wrote into it.
  ///
  /// A call-only turn produces no text, and an empty bubble reads as a model
  /// that said nothing when in fact it asked a question.
  void _dropEmptyReply() {
    if (_reply.isEmpty && _replyAt >= 0 && _replyAt == _turns.length - 1) {
      _turns.removeAt(_replyAt);
    }
  }

  /// Runs one call and shows it. The return value is what the model sees.
  ///
  /// This callback is the whole of the app's half of the loop. Everything
  /// around it — collecting the calls, staging the responses, deciding whether
  /// to generate again — is in the SDK. And it dispatches by NAME, which is
  /// why the second, third and fourth tool cost this file nothing.
  Future<Map<String, dynamic>> _onToolCall(FunctionCallResponse call) async {
    final result = runTool(call);
    // The app reacts to the answer it just produced, rather than to the call:
    // one map is the model's knowledge and the screen's, so they cannot drift.
    final painted = backgroundFrom(result);
    if (mounted) {
      setState(() {
        if (painted != null) _background = painted;
        _dropEmptyReply();
        _turns
          ..add(_Turn(_describeCall(call), kind: _TurnKind.toolCall))
          ..add(_Turn(jsonEncode(result), kind: _TurnKind.toolResult))
          // The next generation writes underneath the work it was given,
          // not above it.
          ..add(const _Turn('', kind: _TurnKind.model));
        _replyAt = _turns.length - 1;
        _thinkAt = -1;
        _reply.clear();
        _thought.clear();
      });
    }
    return result;
  }

  String _describeCall(FunctionCallResponse call) {
    final args = call.args.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(', ');
    return '${call.name}($args)';
  }

  /// Forgets the model. For a downloaded one that frees the disk; for a file
  /// you opened from disk it does NOT — `uninstallModel` deliberately leaves a
  /// `FileSource` alone, because the app never owned that file. The model you
  /// tuned survives being removed here.
  ///
  /// Close the runtime first either way: the file is mapped while a model is
  /// open, and deleting it underneath the engine is a crash waiting to happen.
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
    final settable = ready && !_busy;

    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        title: Text(widget.model.label),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${toolbox.length} tools · '
              '${toolbox.map((t) => t.name).join(', ')}',
              style: theme.textTheme.labelSmall,
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: widget.model.path != null
                ? 'Forget this model (the file stays where it is)'
                : 'Delete the downloaded model',
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
          _SessionSettings(
            model: widget.model,
            toolChoice: _toolChoice,
            thinking: _thinking,
            enabled: settable,
            onToolChoice: (v) => _reopenChat(choice: v),
            onThinking: (v) => _reopenChat(thinking: v),
          ),
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
                            ? 'Try: what time is it, and what is 47 times 89?'
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

/// The two settings that belong to the session rather than to the message.
///
/// They are here, above the transcript, rather than in a settings screen,
/// because changing one throws the conversation away — and a control that
/// does that should be visible while you use it.
class _SessionSettings extends StatelessWidget {
  const _SessionSettings({
    required this.model,
    required this.toolChoice,
    required this.thinking,
    required this.enabled,
    required this.onToolChoice,
    required this.onThinking,
  });

  final ModelChoice model;
  final ToolChoice toolChoice;
  final bool thinking;
  final bool enabled;
  final ValueChanged<ToolChoice> onToolChoice;
  final ValueChanged<bool> onThinking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          SegmentedButton<ToolChoice>(
            segments: const [
              ButtonSegment(value: ToolChoice.auto, label: Text('auto')),
              ButtonSegment(
                value: ToolChoice.required,
                label: Text('required'),
              ),
              ButtonSegment(value: ToolChoice.none, label: Text('none')),
            ],
            selected: {toolChoice},
            showSelectedIcon: false,
            onSelectionChanged: enabled
                ? (selection) => onToolChoice(selection.first)
                : null,
          ),
          const SizedBox(width: 16),
          Text('thinking', style: theme.textTheme.labelLarge),
          Switch(
            value: thinking,
            // Not a greyed-out control with no explanation: the tooltip names
            // the side that refused, the way the multimodal codelab's
            // capability line does.
            onChanged: enabled && model.supportsThinking ? onThinking : null,
          ),
          if (!model.supportsThinking)
            Text(
              '${model.label} does not reason out loud',
              style: theme.textTheme.labelSmall,
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

/// One line of the transcript, drawn so the five kinds are told apart at a
/// glance. The three middle ones are the point of this screen.
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
      _TurnKind.thinking => ('thinking', scheme.surfaceContainerLow),
      _TurnKind.toolCall => ('the model asked for', scheme.tertiaryContainer),
      _TurnKind.toolResult => (
        'your function answered',
        scheme.secondaryContainer,
      ),
    };
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
              style: switch (turn.kind) {
                _TurnKind.toolCall || _TurnKind.toolResult =>
                  theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
                // Reasoning is not the answer, and it should not be read as
                // one: same size, quieter.
                _TurnKind.thinking => theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                ),
                _ => null,
              },
            ),
          ],
        ),
      ),
    );
  }
}
