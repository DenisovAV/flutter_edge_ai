import 'package:flutter/material.dart';

import '../secret_store.dart';
import '../skill.dart';

/// Enter the API key / secret for a `require-secret` skill.
///
/// SECURITY: the value is written to the [SecretStore] only — it is NEVER shown
/// in the chat, never placed in the model prompt, and is injected into the
/// executor as the `secret` argument at execution time. Mirrors Gallery's
/// `SecretEditorDialog` (masked field with a show/hide toggle).
class SecretEditorDialog extends StatefulWidget {
  const SecretEditorDialog({
    super.key,
    required this.skill,
    required this.store,
    this.onSaved,
  });

  /// The skill whose secret is being entered (drives the title + the
  /// `require-secret-description` hint).
  final Skill skill;

  /// Where the entered secret is stored (keyed by [Skill.name]).
  final SecretStore store;

  /// Called after the secret is saved, with the (non-empty) value.
  final ValueChanged<String>? onSaved;

  /// Show the dialog for [skill], persisting into [store]. Resolves to `true`
  /// when a secret was saved, `false` when cancelled / dismissed.
  static Future<bool> show(
    BuildContext context, {
    required Skill skill,
    required SecretStore store,
    ValueChanged<String>? onSaved,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) =>
          SecretEditorDialog(skill: skill, store: store, onSaved: onSaved),
    );
    return saved ?? false;
  }

  @override
  State<SecretEditorDialog> createState() => _SecretEditorDialogState();
}

class _SecretEditorDialogState extends State<SecretEditorDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.store.get(widget.skill.name) ?? '',
  );
  bool _obscured = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      // Empty → clear any stored secret rather than store a blank one.
      widget.store.remove(widget.skill.name);
    } else {
      widget.store.set(widget.skill.name, value);
      widget.onSaved?.call(value);
    }
    Navigator.of(context).pop(value.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final hint = widget.skill.metadata.secretDescription;
    return AlertDialog(
      title: Text('Secret for ${widget.skill.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hint != null && hint.isNotEmpty) ...[
            Text(hint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: _obscured,
            decoration: InputDecoration(
              labelText: 'API key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscured ? 'Show' : 'Hide',
                icon: Icon(_obscured ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Done')),
      ],
    );
  }
}
