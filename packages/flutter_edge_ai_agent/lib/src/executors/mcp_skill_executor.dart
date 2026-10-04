import 'dart:convert';

import '../skill.dart';
import '../skill_executor.dart';
import '../skill_result.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_server_config.dart';

/// A per-call permission request the host decides on. [toolName] is the MCP tool
/// the model wants to run and [input] is the raw JSON-string argument it passed,
/// so the host can show them in a confirmation dialog.
class McpPermissionRequest {
  const McpPermissionRequest({required this.toolName, required this.input});

  /// The MCP tool the model wants to call.
  final String toolName;

  /// The raw, model-supplied JSON-string argument (untrusted) — show it to the
  /// user verbatim so they can review what the tool would receive.
  final String input;
}

/// Decides whether a single MCP tool call may proceed. The host wires this to a
/// dialog ("Allow once" / "Deny"). Return true to allow, false to deny.
typedef McpPermissionHook = Future<bool> Function(McpPermissionRequest request);

/// Executor for [SkillType.mcp] skills — calls a tool on a connected MCP server
/// over Streamable HTTP (mirrors Gallery's `runMcpTool` in `AgentTools.kt`).
///
/// Holds a set of connected [McpClient]s (one per [McpServerConfig]); a `runMcp`
/// call carries only the tool name, so the executor finds the server whose
/// enabled tool list contains it — exactly like Gallery's
/// `mcpServers.find { it.toolsList.any { it.name == toolName } }`.
///
/// SECURITY: every call goes through [permissionHook] unless the matched tool is
/// flagged `alwaysAllow`. The hook defaults to **deny** so nothing fires without
/// an explicit host decision; the host wires it to a permission dialog.
class McpSkillExecutor extends SkillExecutor {
  McpSkillExecutor({
    List<McpClient> clients = const [],
    McpPermissionHook? permissionHook,
    this.priority = 0,
  }) : _clients = [...clients],
       _permissionHook = permissionHook ?? _denyByDefault;

  final List<McpClient> _clients;
  final McpPermissionHook _permissionHook;

  /// Probe precedence (see [SkillExecutor.priority]).
  @override
  final int priority;

  @override
  String get name => 'McpSkillExecutor';

  /// The connected MCP clients this executor can route calls to.
  List<McpClient> get clients => List.unmodifiable(_clients);

  /// Register a connected [client] (its [McpClient.connect] should have run so
  /// its tools are known). Replaces any existing client for the same server URL.
  void addClient(McpClient client) {
    _clients.removeWhere((c) => c.config.url == client.config.url);
    _clients.add(client);
  }

  /// Remove the client for [url], if present.
  void removeClient(String url) =>
      _clients.removeWhere((c) => c.config.url == url);

  @override
  bool canExecuteSkill(Skill skill) => skill.type == SkillType.mcp;

  /// Run the MCP tool. For an MCP call the agent loop passes the tool name as
  /// [skill.name] and the model's `input` JSON string as [dataJson].
  @override
  Future<SkillResult> execute(
    Skill skill,
    String dataJson, {
    String? secret,
  }) async {
    final toolName = skill.name;

    // 1. Find the connected server that exports this enabled tool.
    final match = _findTool(toolName);
    if (match == null) {
      return ErrorResult(
        'MCP tool "$toolName" not found on any connected server.',
      );
    }
    final (client, tool) = match;

    // 2. Permission: skip when the user pre-authorized this tool; otherwise ask
    //    the host (default-deny).
    if (!tool.alwaysAllow) {
      final allowed = await _permissionHook(
        McpPermissionRequest(toolName: toolName, input: dataJson),
      );
      if (!allowed) {
        return const ErrorResult('Permission denied by user');
      }
    }

    // 3. Parse the model's input JSON into the tool's arguments map.
    final Map<String, dynamic> arguments;
    try {
      arguments = _parseArguments(dataJson);
    } catch (_) {
      return ErrorResult(
        'Invalid input for MCP tool "$toolName": expected a JSON object.',
      );
    }

    // 4. Call the tool and map the result.
    try {
      final result = await client.callTool(toolName, arguments);
      if (result.isError) {
        return ErrorResult(
          result.text.isEmpty ? 'MCP tool "$toolName" failed.' : result.text,
        );
      }
      return TextResult(result.text);
    } on McpException catch (e) {
      return ErrorResult(e.message);
    }
  }

  /// The first connected client whose enabled tools include [toolName], paired
  /// with that [McpTool]; null when no connected server exports it.
  (McpClient, McpTool)? _findTool(String toolName) {
    for (final client in _clients) {
      if (!client.config.enabled) continue;
      for (final tool in client.tools) {
        if (tool.name == toolName && tool.enabled) return (client, tool);
      }
    }
    return null;
  }

  /// Decode the model-supplied `input` into the arguments map. An empty string
  /// means "no arguments" (`{}`); anything else must decode to a JSON object.
  Map<String, dynamic> _parseArguments(String dataJson) {
    final trimmed = dataJson.trim();
    if (trimmed.isEmpty) return const {};
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) {
      throw const FormatException('input is not a JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static Future<bool> _denyByDefault(McpPermissionRequest _) async => false;
}
