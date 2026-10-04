/// Configuration for a single MCP (Model Context Protocol) server reachable over
/// Streamable HTTP, plus the tools it exports.
///
/// Mirrors Gallery's `McpServer` proto / `McpServerState` (one server → a list of
/// [McpTool]s, each independently enable-able and "always allow"-able). A server
/// is connected by [McpClient.connect], which fills [tools] from the server's
/// `tools/list` response.
library;

/// One tool exported by an MCP server (from the server's `tools/list` reply).
///
/// Reference type (not a value type): [copyWith] builds a new object, but
/// equal-fielded instances are not `==`. Tools are matched by [name].
class McpTool {
  const McpTool({
    required this.name,
    this.description = '',
    this.inputSchema = const {},
    this.enabled = true,
    this.alwaysAllow = false,
  });

  /// The tool name the model calls via the `runMcp` agent tool.
  final String name;

  /// Human-readable description from the server (used in the tools prompt).
  final String description;

  /// The tool's JSON-schema `inputSchema` object (may be empty).
  final Map<String, dynamic> inputSchema;

  /// Whether the user has this tool enabled (disabled tools are hidden from the
  /// model and refused at call time). Mirrors Gallery's per-tool `enabled`.
  final bool enabled;

  /// Whether the user pre-authorized this tool ("Always allow"), so a call
  /// bypasses the per-call permission hook. Mirrors Gallery's `alwaysAllow`.
  final bool alwaysAllow;

  McpTool copyWith({
    String? name,
    String? description,
    Map<String, dynamic>? inputSchema,
    bool? enabled,
    bool? alwaysAllow,
  }) {
    return McpTool(
      name: name ?? this.name,
      description: description ?? this.description,
      inputSchema: inputSchema ?? this.inputSchema,
      enabled: enabled ?? this.enabled,
      alwaysAllow: alwaysAllow ?? this.alwaysAllow,
    );
  }

  @override
  String toString() => 'McpTool($name, enabled: $enabled)';
}

/// A configured MCP server: its [url], optional auth header, and the [tools] it
/// exports once connected.
///
/// Auth is the Gallery "request header" method (a single header name/value); the
/// OAuth method is out of scope for this slice. Construct with [tools] empty and
/// let [McpClient.connect] populate them, or pass cached tools for offline UI.
///
/// Reference type (not a value type): [copyWith] builds a new object, but
/// equal-fielded instances are not `==`. Servers are identified by [url].
class McpServerConfig {
  const McpServerConfig({
    required this.url,
    this.name = '',
    this.version = '',
    this.headerName,
    this.headerValue,
    this.enabled = true,
    this.tools = const [],
  });

  /// The Streamable-HTTP MCP endpoint URL (e.g. `https://host/mcp`).
  final String url;

  /// Server `name` reported during initialize (filled on connect). May be empty.
  final String name;

  /// Server `version` reported during initialize (filled on connect).
  final String version;

  /// Optional auth header name (Gallery's `request_header` auth). Sent on every
  /// request when both [headerName] and [headerValue] are non-null.
  final String? headerName;

  /// Optional auth header value (e.g. `Bearer …`). NEVER logged.
  final String? headerValue;

  /// Whether this whole server is enabled.
  final bool enabled;

  /// The tools this server exports (filled by [McpClient.connect]).
  final List<McpTool> tools;

  /// The auth headers to attach to every request, or empty when unauthenticated.
  Map<String, String> get authHeaders {
    final n = headerName;
    final v = headerValue;
    // Both name AND value must be non-empty — an empty value would otherwise
    // send a blank-valued header on every request.
    if (n == null || v == null || n.isEmpty || v.isEmpty) return const {};
    return {n: v};
  }

  /// The enabled tool with [toolName], or null if absent/disabled.
  McpTool? findEnabledTool(String toolName) {
    for (final tool in tools) {
      if (tool.name == toolName && tool.enabled) return tool;
    }
    return null;
  }

  McpServerConfig copyWith({
    String? url,
    String? name,
    String? version,
    String? headerName,
    String? headerValue,
    bool? enabled,
    List<McpTool>? tools,
  }) {
    return McpServerConfig(
      url: url ?? this.url,
      name: name ?? this.name,
      version: version ?? this.version,
      headerName: headerName ?? this.headerName,
      headerValue: headerValue ?? this.headerValue,
      enabled: enabled ?? this.enabled,
      tools: tools ?? this.tools,
    );
  }

  @override
  String toString() =>
      'McpServerConfig($url, ${tools.length} tools, enabled: $enabled)';
}
