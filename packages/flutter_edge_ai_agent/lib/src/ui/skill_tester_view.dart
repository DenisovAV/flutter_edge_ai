import 'package:flutter/material.dart';

import '../secret_store.dart';
import '../skill.dart';
import '../skill_executor.dart';
import '../skill_result.dart';
import 'skill_result_view.dart';

/// Run a single [Skill] in isolation with manual JSON input, for debugging.
///
/// Picks the first registered [SkillExecutor] whose `canExecute` is true (the
/// same probe-chain the agent loop uses), runs it with the entered `dataJson`
/// (and any stored secret), and shows the [SkillResult] inline. Mirrors
/// Gallery's `SkillTesterBottomSheet` — no model in the loop, so you can verify a
/// skill's mechanics directly.
class SkillTesterView extends StatefulWidget {
  const SkillTesterView({
    super.key,
    required this.skill,
    required this.executors,
    this.secretStore,
  });

  /// The skill to test.
  final Skill skill;

  /// The registered executors to probe (same list as the agent loop).
  final List<SkillExecutor> executors;

  /// Optional secret source for a `require-secret` skill.
  final SecretStore? secretStore;

  /// Show the tester as a modal bottom sheet (debug surface).
  static Future<void> show(
    BuildContext context, {
    required Skill skill,
    required List<SkillExecutor> executors,
    SecretStore? secretStore,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: SkillTesterView(
          skill: skill,
          executors: executors,
          secretStore: secretStore,
        ),
      ),
    );
  }

  @override
  State<SkillTesterView> createState() => _SkillTesterViewState();
}

class _SkillTesterViewState extends State<SkillTesterView> {
  final _dataController = TextEditingController(text: '{}');
  SkillResult? _result;
  bool _running = false;

  @override
  void dispose() {
    _dataController.dispose();
    super.dispose();
  }

  SkillExecutor? get _executor {
    for (final executor in widget.executors) {
      if (executor.canExecuteSkill(widget.skill)) return executor;
    }
    return null;
  }

  Future<void> _run() async {
    final executor = _executor;
    if (executor == null) {
      setState(
        () => _result = const ErrorResult(
          'No registered executor can run this skill type.',
        ),
      );
      return;
    }
    setState(() {
      _running = true;
      _result = null;
    });
    SkillResult result;
    try {
      result = await executor.execute(
        widget.skill,
        _dataController.text,
        secret: widget.secretStore?.get(widget.skill.name),
      );
    } catch (e) {
      result = ErrorResult('$e');
    }
    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final executorName = _executor?.name ?? 'none';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.skill.name, style: theme.textTheme.titleLarge),
          Text(
            'Type: ${widget.skill.type.name} • Executor: $executorName',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dataController,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'Input data (JSON)',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: _running
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(_running ? 'Running…' : 'Run'),
            ),
          ),
          const SizedBox(height: 12),
          Text('Result', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: _result == null
                    ? Text(
                        'Run the skill to see its result.',
                        style: theme.textTheme.bodySmall,
                      )
                    : SkillResultView(result: _result!),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
