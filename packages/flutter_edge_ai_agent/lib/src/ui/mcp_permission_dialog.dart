import 'dart:convert';

import 'package:flutter/material.dart';

/// The user's decision for a single MCP tool-call permission prompt. Mirrors
/// Gallery's `PermissionResult`.
enum McpPermissionResult {
  /// Authorize this call and remember the choice ("Always allow" → flips the
  /// tool's `alwaysAllow` so future calls skip the prompt).
  alwaysAllow,

  /// Authorize just this one call.
  allowOnce,

  /// Refuse the call (the loop feeds a refusal back to the model).
  deny,
}

/// Per-tool-call permission prompt for an MCP tool the model wants to run.
///
/// Shown before [McpSkillExecutor] sends a `tools/call`, unless the tool is
/// pre-authorized (`alwaysAllow`). Mirrors Gallery's `McpToolCallPermissionDialog`
/// — three outcomes (always allow / allow once / don't allow) and a pretty-printed
/// view of the arguments the model is sending so the user can vet them.
class McpToolCallPermissionDialog extends StatelessWidget {
  const McpToolCallPermissionDialog({
    super.key,
    required this.toolName,
    required this.argumentJson,
    this.serverName,
  });

  /// The MCP tool the model is asking to call.
  final String toolName;

  /// The raw JSON-string arguments the model is sending (pretty-printed for
  /// display).
  final String argumentJson;

  /// The server the tool belongs to, shown for context when known.
  final String? serverName;

  /// Show the dialog and resolve to the user's [McpPermissionResult]. A barrier
  /// dismiss / back resolves to [McpPermissionResult.deny] (fail-safe).
  static Future<McpPermissionResult> show(
    BuildContext context, {
    required String toolName,
    required String argumentJson,
    String? serverName,
  }) async {
    final result = await showDialog<McpPermissionResult>(
      context: context,
      builder: (_) => McpToolCallPermissionDialog(
        toolName: toolName,
        argumentJson: argumentJson,
        serverName: serverName,
      ),
    );
    return result ?? McpPermissionResult.deny;
  }

  String get _prettyArgs {
    final trimmed = argumentJson.trim();
    if (trimmed.isEmpty) return '{}';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
    } catch (_) {
      return argumentJson;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.shield_outlined),
      title: const Text('Allow tool call?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (serverName != null && serverName!.isNotEmpty) ...[
              Text('Server', style: theme.textTheme.labelMedium),
              Text(serverName!, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
            ],
            Text('Tool', style: theme.textTheme.labelMedium),
            Text(toolName, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text('Input', style: theme.textTheme.labelMedium),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _prettyArgs,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(McpPermissionResult.deny),
          child: const Text("Don't allow"),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(McpPermissionResult.allowOnce),
          child: const Text('Allow once'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(McpPermissionResult.alwaysAllow),
          child: const Text('Always allow'),
        ),
      ],
    );
  }
}
