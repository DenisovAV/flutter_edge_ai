import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';

import 'model.dart';
import 'skills.dart';

/// A chat with an agent, which shows what the agent did as well as what it
/// said.
///
/// `AgentSession.ask` is a stream of [AgentEvent]s, not of text: the model
/// loads a skill, calls a tool, reads the result, and writes its answer, and
/// each of those is an event. This page puts the steps under the reply, so
/// you can see which skill answered — and notice when none did.
class AgentPage extends StatefulWidget {
  const AgentPage({
    super.key,
    required this.model,
    required this.onModelRemoved,
  });

  final ModelChoice model;

  /// Lets the gate send the app back to the download screen.
  final VoidCallback onModelRemoved;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  final _input = TextEditingController();
  final _turns = <_Turn>[];

  InferenceModel? _inference;
  AgentSession? _agent;
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
      // maxTokens is the CONTEXT WINDOW, and an agent fills it faster than a
      // chat: the skill list, each loaded skill's instructions and every tool
      // result are part of the conversation.
      final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
      // Hold the runtime before opening anything on it: a model this page
      // never stored is a model `dispose` can never close.
      if (!mounted) {
        await inference.close();
        return;
      }
      setState(() => _inference = inference);

      final agent = await openAgent(
        inference,
        modelType: widget.model.modelType,
      );
      if (!mounted) {
        await agent.close();
        return;
      }
      setState(() => _agent = agent);
    } catch (error) {
      // A missing engine, too little memory, a skill that does not parse:
      // show it instead of sitting on the progress bar forever.
      if (mounted) setState(() => _loadError = error);
    }
  }

  void _retryLoad() {
    setState(() => _loadError = null);
    _load();
  }

  Future<void> _send() async {
    final agent = _agent;
    final text = _input.text.trim();
    if (agent == null || text.isEmpty || _busy) return;

    final reply = _Turn(fromUser: false);
    setState(() {
      _turns
        ..add(_Turn(fromUser: true, text: text))
        ..add(reply);
      _input.clear();
      _busy = true;
    });

    try {
      // isCancelled: a page that is gone stops the loop at its next step,
      // instead of letting it run a tool — open a mail composer — for nobody.
      await for (final event in agent.ask(text, isCancelled: () => !mounted)) {
        if (!mounted) return;
        setState(() => _apply(reply, event));
      }
    } catch (error) {
      // The conversation may now end on a question with no answer; New
      // conversation starts a clean one.
      if (mounted) setState(() => reply.steps.add('⚠️ $error'));
    } finally {
      // `_busy` disables the composer, so clearing it belongs in `finally`:
      // a failed turn must not lock the app.
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Folds one [event] into the reply bubble.
  ///
  /// The switch is exhaustive: [AgentEvent] is sealed, so a new kind of event
  /// in a later version of the package is a compile error here, not a step
  /// that silently goes missing.
  void _apply(_Turn reply, AgentEvent event) {
    // Every event but text is a step of the loop: loading a skill, calling a
    // tool, reading its result. What streamed before it was the model working
    // toward that step — or the call itself in raw form — not the answer. The
    // answer is what comes after the last step, so start the text over.
    if (event is! TextChunkEvent && event is! DoneEvent) reply.text = '';
    switch (event) {
      case SkillLoadEvent(:final skillName, :final found):
        // A skill that is not there gets an AgentErrorEvent right after,
        // which says so: one line per failure.
        if (found) reply.steps.add('📖 loaded skill $skillName');
      case ToolCallEvent(:final toolName, :final args):
        reply.steps.add('🔧 $toolName $args');
      case ToolResultEvent(:final result):
        // The same: a failed result is followed by an AgentErrorEvent.
        if (result is! ErrorResult) reply.steps.add('↩️ ${_describe(result)}');
        // A skill can answer with an image — qr-code does. The model only
        // learns that an image was made; the app is what shows it.
        if (result is ImageResult) reply.images.add(result.bytes);
      case TextChunkEvent(:final text):
        // Each chunk carries only the NEW text — append, never replace.
        reply.text += text;
      case DoneEvent(:final text):
        // The final answer: the text after the last step, whole.
        reply.text = text;
        if (text.trim().isEmpty) {
          reply.steps.add('∅ the model ended the turn without an answer');
        }
      case MaxIterationsEvent(:final iterations):
        reply.steps.add('⏹ stopped after $iterations steps');
      case AgentErrorEvent(:final message):
        reply.steps.add('⚠️ $message');
    }
  }

  static String _describe(SkillResult result) => switch (result) {
    // `characters`, not `substring`: a cut must not split an emoji in two.
    TextResult(:final text) =>
      text.characters.length > 120 ? '${text.characters.take(120)}…' : text,
    ImageResult() => 'an image',
    WidgetResult() => 'a widget',
    WebviewResult(:final url) => 'a page: $url',
    ErrorResult(:final message) => 'error: $message',
  };

  /// Starts over: the agent forgets the conversation and the page clears.
  ///
  /// One session holds the whole conversation — a skill can ask a follow-up
  /// question — and every loaded skill and tool result stays in its context
  /// window. A few skill turns fill 4096 tokens, so the app needs a way to
  /// start over without reloading the model.
  Future<void> _newConversation() async {
    final agent = _agent;
    if (agent == null || _busy) return;
    await agent.chat.clearHistory();
    if (mounted) setState(_turns.clear);
  }

  /// Frees the disk. Takes the agent and the runtime off the page first, so
  /// nothing can use them — or delete twice — while they close; then closes
  /// them, since the file is mapped while a model is open.
  Future<void> _removeModel() async {
    final agent = _agent;
    final inference = _inference;
    setState(() {
      _removing = true;
      _agent = null;
      _inference = null;
      _loadError = null;
      _removeError = null;
    });
    try {
      await _close(agent, inference);
      await FlutterEdgeAi.uninstallModel(widget.model.fileName);
      if (mounted) widget.onModelRemoved();
    } catch (error) {
      // Say what failed, and offer the delete again, not a reload.
      if (mounted) {
        setState(() {
          _removing = false;
          _removeError = error;
        });
      }
    }
  }

  /// The agent first, then the model it runs on — even if the agent's close
  /// throws. Closing the agent closes only its chat; the model is the page's.
  static Future<void> _close(
    AgentSession? agent,
    InferenceModel? inference,
  ) async {
    try {
      await agent?.close();
    } finally {
      await inference?.close();
    }
  }

  @override
  void dispose() {
    // `dispose` cannot await, so the closes run on their own, and a failure is
    // reported rather than dropped: a model that did not close may still hold
    // its memory.
    _close(_agent, _inference).catchError(_reportCloseError);
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _agent != null;
    final error = _loadError;
    final removeError = _removeError;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.model.label} agent'),
        actions: [
          IconButton(
            tooltip: 'New conversation',
            onPressed: ready && !_busy && _turns.isNotEmpty
                ? _newConversation
                : null,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: 'Delete the downloaded model',
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
              title: 'The agent did not start.',
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
          if (_busy) const LinearProgressIndicator(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: ready && !_busy,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: ready
                            ? 'Ask the agent'
                            : error != null || removeError != null
                            ? 'No agent'
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
      context: ErrorDescription('while closing the agent'),
    ),
  );
}

/// Shown in place of the loading bar when starting the agent or deleting the
/// model failed, with a button that tries that again.
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

/// One message. An agent's reply also carries the [steps] it took.
class _Turn {
  _Turn({required this.fromUser, this.text = ''});

  final bool fromUser;
  String text;
  final steps = <String>[];
  final images = <Uint8List>[];
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final _Turn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Align(
      alignment: turn.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: turn.fromUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final step in turn.steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  step,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final image in turn.images)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Image.memory(image, width: 200),
              ),
            if (turn.text.isNotEmpty) SelectableText(turn.text),
          ],
        ),
      ),
    );
  }
}
