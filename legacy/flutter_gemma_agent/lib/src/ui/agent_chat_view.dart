import 'dart:async';

import 'package:flutter/material.dart';

import '../agent_event.dart';
import '../agent_session.dart';
import '../skill_result.dart';
import 'skill_result_view.dart';

/// One bubble in the agent chat transcript.
class _ChatTurn {
  _ChatTurn({required this.isUser, this.text = ''});

  final bool isUser;
  String text;

  /// Inline rich results (image / webview / native widget) produced by skills
  /// during this (model) turn, shown under the text.
  final List<SkillResult> results = [];

  /// Progress steps the agent emitted while producing this turn ("Loading skill
  /// X", "Running runIntent", …). Shown in a collapsible panel.
  final List<_ProgressStep> steps = [];
}

/// A single line in the collapsible progress panel.
class _ProgressStep {
  _ProgressStep(this.icon, this.label, {this.isError = false});

  final IconData icon;
  final String label;
  final bool isError;
}

/// A cross-platform chat widget driven by an [AgentSession]'s `Stream<AgentEvent>`.
///
/// Renders user / model bubbles, a COLLAPSIBLE progress panel per model turn
/// showing the agent's steps (skill loads, tool calls, errors), and inline
/// image / webview / native-widget skill results. Mirrors Gallery's
/// `AgentChatScreen` UX but is platform-adaptive and renders [WidgetResult]
/// natively. The host owns the [session]; this widget only drives [AgentSession.ask]
/// and consumes its events.
class AgentChatView extends StatefulWidget {
  const AgentChatView({
    super.key,
    required this.session,
    this.hintText = 'Ask the agent…',
    this.emptyState,
  });

  /// The agent session to drive. The host creates it (e.g. via
  /// [AgentSession.fromModel]) and is responsible for closing it.
  final AgentSession session;

  /// Placeholder for the input field.
  final String hintText;

  /// Optional widget shown when the transcript is empty.
  final Widget? emptyState;

  @override
  State<AgentChatView> createState() => _AgentChatViewState();
}

class _AgentChatViewState extends State<AgentChatView> {
  final _turns = <_ChatTurn>[];
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();

  StreamSubscription<AgentEvent>? _subscription;
  bool _busy = false;

  @override
  void dispose() {
    _subscription?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _inputController.text.trim();
    if (text.isEmpty || _busy) return;
    _inputController.clear();

    final modelTurn = _ChatTurn(isUser: false);
    setState(() {
      _busy = true;
      _turns
        ..add(_ChatTurn(isUser: true, text: text))
        ..add(modelTurn);
    });
    _scrollToBottom();

    _subscription = widget.session
        .ask(text)
        .listen(
          (event) => _onEvent(event, modelTurn),
          onError: (Object e) {
            setState(() {
              modelTurn.steps.add(
                _ProgressStep(Icons.error_outline, '$e', isError: true),
              );
              _busy = false;
            });
            _scrollToBottom();
          },
          onDone: () {
            if (mounted) setState(() => _busy = false);
            _scrollToBottom();
          },
        );
  }

  void _onEvent(AgentEvent event, _ChatTurn turn) {
    setState(() {
      switch (event) {
        case SkillLoadEvent(:final skillName, :final found):
          turn.steps.add(
            _ProgressStep(
              found ? Icons.menu_book_outlined : Icons.help_outline,
              found
                  ? 'Loading skill "$skillName"'
                  : 'Skill "$skillName" not found',
              isError: !found,
            ),
          );
        case ToolCallEvent(:final toolName, :final skill):
          final target = skill?.name ?? toolName;
          turn.steps.add(
            _ProgressStep(Icons.play_arrow_outlined, 'Running $target'),
          );
        case ToolResultEvent(:final result):
          // Surface rich results inline; text/errors stay in the step list.
          switch (result) {
            case ImageResult() || WidgetResult() || WebviewResult():
              turn.results.add(result);
              turn.steps.add(
                _ProgressStep(Icons.check_circle_outline, 'Result ready'),
              );
            case TextResult():
              turn.steps.add(
                _ProgressStep(Icons.check_circle_outline, 'Tool finished'),
              );
            case ErrorResult(:final message):
              turn.steps.add(
                _ProgressStep(Icons.error_outline, message, isError: true),
              );
          }
        case TextChunkEvent(:final text):
          turn.text += text;
        case DoneEvent(:final text):
          if (turn.text.isEmpty) turn.text = text;
        case MaxIterationsEvent(:final iterations):
          turn.steps.add(
            _ProgressStep(
              Icons.timelapse,
              'Stopped after $iterations steps',
              isError: true,
            ),
          );
        case AgentErrorEvent(:final message):
          turn.steps.add(
            _ProgressStep(Icons.error_outline, message, isError: true),
          );
      }
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _turns.isEmpty
              ? Center(child: widget.emptyState ?? const _DefaultEmptyState())
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _turns.length,
                  itemBuilder: (context, i) => _AgentTurnBubble(
                    turn: _turns[i],
                    // Show the spinner on the last (model) turn while busy.
                    isStreaming:
                        _busy && i == _turns.length - 1 && !_turns[i].isUser,
                  ),
                ),
        ),
        const Divider(height: 1),
        _Composer(
          controller: _inputController,
          hintText: widget.hintText,
          busy: _busy,
          onSend: _send,
        ),
      ],
    );
  }
}

class _DefaultEmptyState extends StatelessWidget {
  const _DefaultEmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome,
            size: 40,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'Ask the agent to do something with your selected skills.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _AgentTurnBubble extends StatelessWidget {
  const _AgentTurnBubble({required this.turn, required this.isStreaming});

  final _ChatTurn turn;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final align = turn.isUser
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;
    final bubbleColor = turn.isUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: align,
        children: [
          if (!turn.isUser && turn.steps.isNotEmpty)
            _ProgressPanel(steps: turn.steps),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (turn.text.isNotEmpty)
                    SelectableText(turn.text)
                  else if (turn.isUser || !isStreaming)
                    // A finished model turn with no text and no rich results is
                    // unusual but render nothing rather than an empty bubble gap.
                    const SizedBox.shrink()
                  else
                    const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  for (final result in turn.results) ...[
                    const SizedBox(height: 8),
                    SkillResultView(result: result),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A collapsible panel listing the agent's progress steps for a model turn.
class _ProgressPanel extends StatefulWidget {
  const _ProgressPanel({required this.steps});

  final List<_ProgressStep> steps;

  @override
  State<_ProgressPanel> createState() => _ProgressPanelState();
}

class _ProgressPanelState extends State<_ProgressPanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = widget.steps;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.82,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Agent steps (${steps.length})',
                    style: theme.textTheme.labelMedium,
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final step in steps)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            step.icon,
                            size: 14,
                            color: step.isError
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              step.label,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: step.isError
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.hintText,
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final String hintText;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: hintText,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            busy
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton.filled(
                    onPressed: onSend,
                    icon: const Icon(Icons.send),
                  ),
          ],
        ),
      ),
    );
  }
}
