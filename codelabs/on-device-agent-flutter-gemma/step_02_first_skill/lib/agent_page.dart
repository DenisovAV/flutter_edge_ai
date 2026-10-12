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
  Object? _loadError;

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

      final agent = await openAgent(inference);
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
      await for (final event in agent.ask(text)) {
        if (!mounted) return;
        setState(() => _apply(reply, event));
      }
    } catch (error) {
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
    switch (event) {
      case SkillLoadEvent(:final skillName, :final found):
        reply.steps.add(
          found ? '📖 loaded skill $skillName' : '❓ no skill named $skillName',
        );
      case ToolCallEvent(:final toolName, :final args):
        reply.steps.add('🔧 $toolName $args');
        // What streamed before a tool call is not the answer: the model
        // thinking aloud, or the call itself in raw form. The answer comes
        // after the result, so start the text over.
        reply.text = '';
      case ToolResultEvent(:final result):
        reply.steps.add('↩️ ${_describe(result)}');
      case TextChunkEvent(:final text):
        // Each chunk carries only the NEW text — append, never replace.
        reply.text += text;
      case DoneEvent(:final text):
        // The final answer, whole. Prefer it to the streamed chunks, which
        // may have carried text the model wrote before deciding to call a
        // tool instead.
        if (text.isNotEmpty) reply.text = text;
      case MaxIterationsEvent(:final iterations):
        reply.steps.add('⏹ stopped after $iterations steps');
      case AgentErrorEvent(:final message):
        reply.steps.add('⚠️ $message');
    }
  }

  static String _describe(SkillResult result) => switch (result) {
    TextResult(:final text) =>
      text.length > 120 ? '${text.substring(0, 120)}…' : text,
    ImageResult() => 'an image',
    WidgetResult() => 'a widget',
    WebviewResult(:final url) => 'a page: $url',
    ErrorResult(:final message) => 'error: $message',
  };

  /// Frees the disk. Close the agent and the runtime first — the file is
  /// mapped while a model is open.
  Future<void> _removeModel() async {
    try {
      await _agent?.close();
      await _inference?.close();
      if (mounted) {
        setState(() {
          _agent = null;
          _inference = null;
        });
      }
      await FlutterEdgeAi.uninstallModel(widget.model.fileName);
      if (mounted) widget.onModelRemoved();
    } catch (error) {
      if (mounted) {
        setState(() {
          _agent = null;
          _loadError = error;
        });
      }
    }
  }

  @override
  void dispose() {
    // `dispose` cannot await, so the futures are dropped on purpose, and
    // caught so a failing native teardown is not an unhandled async error.
    _agent?.close().catchError((Object _) {});
    _inference?.close().catchError((Object _) {});
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _agent != null;
    final error = _loadError;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.model.label} agent'),
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
                            : error != null
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

/// Shown in place of the loading bar when the agent could not be opened.
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
          Text('The agent did not start.\n$error', textAlign: TextAlign.center),
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
            if (turn.text.isNotEmpty) SelectableText(turn.text),
          ],
        ),
      ),
    );
  }
}
