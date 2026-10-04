import 'package:flutter/material.dart';

/// The kind of third-party content the user is about to add, so the disclaimer
/// can tailor its wording (a skill ships executable JS / native intents; an MCP
/// server is a remote tool endpoint).
enum DisclaimerKind {
  /// Adding a SKILL.md skill (may carry JavaScript or fire native intents).
  skill,

  /// Adding a remote MCP server (its tools run with the data you pass them).
  mcp,
}

/// A security warning shown before adding a third-party skill or MCP server.
///
/// Skills are third-party code: a JS skill runs foreign JavaScript (sandboxed in
/// a headless webview), a native-intent skill can open the mail / SMS / calendar
/// composer, and an MCP tool sends your arguments to a remote server. This
/// mirrors Gallery's `AddSkillDisclaimerDialog` / `AddMcpDisclaimerDialog` —
/// confirm-to-proceed, cancel-to-abort.
class AddSkillDisclaimerDialog extends StatelessWidget {
  const AddSkillDisclaimerDialog({
    super.key,
    this.kind = DisclaimerKind.skill,
    required this.onConfirm,
  });

  /// Whether the disclaimer is for a skill or an MCP server.
  final DisclaimerKind kind;

  /// Called when the user agrees to proceed. The dialog pops itself first.
  final VoidCallback onConfirm;

  /// Show the disclaimer and resolve to `true` when the user agrees, `false`
  /// (or null → treated as false by callers) when they cancel / dismiss.
  static Future<bool> show(
    BuildContext context, {
    DisclaimerKind kind = DisclaimerKind.skill,
  }) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AddSkillDisclaimerDialog(
        kind: kind,
        onConfirm: () => Navigator.of(context).pop(true),
      ),
    );
    return agreed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isMcp = kind == DisclaimerKind.mcp;
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
      title: Text(isMcp ? 'Add MCP server' : 'Add skill'),
      content: Text(
        isMcp
            ? 'MCP servers are third-party services. Tools you enable can run '
                  'with the arguments the model sends them, and your input is '
                  'transmitted to the server you configure. Only add servers you '
                  'trust. You will still be asked to confirm each tool call.'
            : 'Skills are third-party code. A skill may run JavaScript (in a '
                  'sandboxed webview) or open native composers (email, SMS, '
                  'calendar, notifications). Only add skills from sources you '
                  'trust. You confirm any outgoing action before it is sent.',
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: onConfirm, child: const Text('I understand')),
      ],
    );
  }
}
