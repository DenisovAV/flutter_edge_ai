import 'package:flutter/material.dart';

import '../mcp/mcp_client.dart';
import '../mcp/mcp_server_config.dart';
import 'add_skill_disclaimer.dart';

/// Manage the configured MCP servers and their tools.
///
/// Lists each server, its connection state, and its tools with per-tool enable
/// and "always allow" toggles (mirrors Gallery's `McpManagerBottomSheet` +
/// `McpToolManagerBottomSheet`). Adding a server goes through the MCP disclaimer
/// then connects via [McpClient] to discover its tools. The host owns the list
/// of [McpServerConfig]s; this view mutates a working copy and reports changes
/// through [onChanged]. Adaptive: bottom sheet on narrow, side panel on wide.
class McpManagerView extends StatefulWidget {
  const McpManagerView({
    super.key,
    required this.servers,
    required this.onChanged,
    this.clientFactory,
  });

  /// The configured servers to display (a snapshot; edits are reported via
  /// [onChanged]).
  final List<McpServerConfig> servers;

  /// Called with the full updated server list whenever the user adds / removes a
  /// server or toggles a tool, so the host can persist it.
  final ValueChanged<List<McpServerConfig>> onChanged;

  /// Builds an [McpClient] for a server, so a host can inject a fake in tests or
  /// supply a custom HTTP client. Defaults to a plain [McpClient].
  final McpClient Function(McpServerConfig config)? clientFactory;

  /// Show the manager adaptively (bottom sheet < 600 dp, side panel otherwise).
  static Future<void> showAdaptive(
    BuildContext context, {
    required List<McpServerConfig> servers,
    required ValueChanged<List<McpServerConfig>> onChanged,
    McpClient Function(McpServerConfig config)? clientFactory,
  }) {
    final view = McpManagerView(
      servers: servers,
      onChanged: onChanged,
      clientFactory: clientFactory,
    );
    final wide = MediaQuery.of(context).size.width >= 600;
    if (wide) {
      return showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          alignment: Alignment.centerRight,
          insetPadding: const EdgeInsets.all(16),
          child: SizedBox(
            width: 420,
            height: double.infinity,
            child: _McpPanel(child: view),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: _McpPanel(child: view),
      ),
    );
  }

  @override
  State<McpManagerView> createState() => _McpManagerViewState();
}

class _McpManagerViewState extends State<McpManagerView> {
  late List<McpServerConfig> _servers = List.of(widget.servers);
  bool _connecting = false;

  void _commit() {
    setState(() {});
    widget.onChanged(List.of(_servers));
  }

  Future<void> _addServer() async {
    final agreed = await AddSkillDisclaimerDialog.show(
      context,
      kind: DisclaimerKind.mcp,
    );
    if (!agreed || !mounted) return;

    final entered = await _promptForServer();
    if (entered == null || !mounted) return;

    setState(() => _connecting = true);
    final client = (widget.clientFactory ?? McpClient.new)(entered);
    try {
      final connected = await client.connect();
      _servers = [..._servers, connected];
      _commit();
    } catch (e) {
      // Keep the server (offline) so the user can retry / remove it.
      _servers = [..._servers, entered];
      _commit();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added but could not connect: $e')),
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _removeServer(int index) {
    _servers = [..._servers]..removeAt(index);
    _commit();
  }

  void _replaceServer(int index, McpServerConfig updated) {
    _servers = [..._servers];
    _servers[index] = updated;
    _commit();
  }

  Future<McpServerConfig?> _promptForServer() {
    final urlController = TextEditingController();
    final headerNameController = TextEditingController();
    final headerValueController = TextEditingController();
    return showDialog<McpServerConfig>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add MCP server'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://host/mcp',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: headerNameController,
                decoration: const InputDecoration(
                  labelText: 'Auth header name (optional)',
                  hintText: 'Authorization',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: headerValueController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Auth header value (optional)',
                  hintText: 'Bearer …',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final url = urlController.text.trim();
              if (url.isEmpty) {
                Navigator.of(context).pop();
                return;
              }
              final headerName = headerNameController.text.trim();
              final headerValue = headerValueController.text.trim();
              Navigator.of(context).pop(
                McpServerConfig(
                  url: url,
                  headerName: headerName.isEmpty ? null : headerName,
                  headerValue: headerValue.isEmpty ? null : headerValue,
                ),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: OutlinedButton.icon(
            onPressed: _connecting ? null : _addServer,
            icon: _connecting
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add, size: 18),
            label: const Text('Add server'),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _servers.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No MCP servers. Add one to give the agent remote tools.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _servers.length,
                  itemBuilder: (context, i) => _ServerCard(
                    config: _servers[i],
                    onRemove: () => _removeServer(i),
                    onConfigChanged: (updated) => _replaceServer(i, updated),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.config,
    required this.onRemove,
    required this.onConfigChanged,
  });

  final McpServerConfig config;
  final VoidCallback onRemove;
  final ValueChanged<McpServerConfig> onConfigChanged;

  void _setTool(int index, McpTool tool) {
    final tools = [...config.tools];
    tools[index] = tool;
    onConfigChanged(config.copyWith(tools: tools));
  }

  @override
  Widget build(BuildContext context) {
    final title = config.name.isNotEmpty ? config.name : config.url;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        leading: const Icon(Icons.cloud_outlined),
        title: Text(title, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${config.url} • ${config.tools.length} tools',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          for (final (i, tool) in config.tools.indexed)
            ListTile(
              dense: true,
              title: Text(tool.name),
              subtitle: tool.description.isEmpty
                  ? null
                  : Text(
                      tool.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: 'Always allow',
                    child: IconButton(
                      icon: Icon(
                        tool.alwaysAllow
                            ? Icons.verified_user
                            : Icons.shield_outlined,
                        size: 18,
                        color: tool.alwaysAllow
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      onPressed: () => _setTool(
                        i,
                        tool.copyWith(alwaysAllow: !tool.alwaysAllow),
                      ),
                    ),
                  ),
                  Switch(
                    value: tool.enabled,
                    onChanged: (v) => _setTool(i, tool.copyWith(enabled: v)),
                  ),
                ],
              ),
            ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Remove server'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _McpPanel extends StatelessWidget {
  const _McpPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Text(
                'MCP servers',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
