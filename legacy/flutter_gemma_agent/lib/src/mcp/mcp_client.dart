import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_server_config.dart';

/// Thrown when an MCP request fails at the transport or JSON-RPC layer.
class McpException implements Exception {
  McpException(this.message);

  final String message;

  @override
  String toString() => 'McpException: $message';
}

/// The text content of a `tools/call` result, plus whether the server flagged it
/// an error. Mirrors Gallery's `TextContent` extraction (`isError` + joined
/// `text` items).
class McpToolResult {
  const McpToolResult({required this.text, required this.isError});

  /// The joined text of every `text` content item in the result.
  final String text;

  /// Whether the server returned `isError: true` (the model should recover).
  final bool isError;

  @override
  String toString() => 'McpToolResult(isError: $isError, ${text.length} chars)';
}

/// A minimal MCP (Model Context Protocol) client over **Streamable HTTP** —
/// JSON-RPC 2.0 POSTed to the server's single endpoint.
///
/// This is the cross-platform equivalent of the Gallery Kotlin SDK's
/// `StreamableHttpClientTransport` + `Client`: [connect] performs the
/// `initialize` handshake (capturing the `Mcp-Session-Id`), sends the
/// `notifications/initialized` notification, and runs `tools/list`; [callTool]
/// runs `tools/call` and extracts the text content.
///
/// Responses may come back as either `application/json` or an SSE
/// (`text/event-stream`) frame — both are handled. The injectable [httpClient]
/// keeps it unit-testable with a fake client.
class McpClient {
  McpClient({
    required this.config,
    http.Client? httpClient,
    this.clientName = 'flutter_gemma_agent',
    this.clientVersion = '0.2.3',
    this.protocolVersion = '2025-11-25',
  }) : _ownsClient = httpClient == null,
       _http = httpClient ?? http.Client(),
       // Seed from any cached tools on the config so a client constructed for
       // offline UI (or in tests) is immediately routable before connect().
       _tools = List.of(config.tools);

  /// The server this client talks to (its [McpServerConfig.url] + auth).
  final McpServerConfig config;

  /// The `clientInfo.name` reported in the initialize handshake.
  final String clientName;

  /// The `clientInfo.version` reported in the initialize handshake.
  final String clientVersion;

  /// The MCP `protocolVersion` advertised in the initialize handshake.
  ///
  /// Defaults to `2025-11-25`. The `2026-07-28` revision (a stateless core,
  /// with no handshake and no `Mcp-Session-Id`) is final, but this client is
  /// built on the initialize handshake plus `Mcp-Session-Id`, so it does not
  /// speak it yet. Override only when the servers you talk to negotiate the
  /// revision you pass — [connect] rejects a server that answers with a
  /// different one.
  final String protocolVersion;

  /// The revision the server echoed in the initialize result. Null until
  /// [connect] runs. Sent as `MCP-Protocol-Version` on every later request.
  String? get negotiatedProtocolVersion => _negotiatedProtocolVersion;
  String? _negotiatedProtocolVersion;

  final http.Client _http;
  final bool _ownsClient;

  /// The session id the server returned in the `Mcp-Session-Id` header of the
  /// initialize response, echoed back on every subsequent request. Null until
  /// [connect] runs (some servers do not use sessions).
  String? _sessionId;

  /// The tools known to this client — seeded from any cached [config.tools] and
  /// refreshed by [connect] / [listTools].
  List<McpTool> _tools;

  /// Monotonic JSON-RPC request id.
  int _nextId = 1;

  /// The tools known on the server (seeded from cached [McpServerConfig.tools],
  /// refreshed by [connect] / [listTools]).
  List<McpTool> get tools => List.unmodifiable(_tools);

  /// The negotiated session id, if any.
  String? get sessionId => _sessionId;

  /// Perform the initialize handshake and load the server's tools, returning a
  /// [config] copy whose [McpServerConfig.tools] / name / version are filled in.
  ///
  /// Preserves the enabled / alwaysAllow flags of any tools already on [config]
  /// (so a reconnect keeps the user's preferences), exactly like Gallery's
  /// `initializeClientAndLoadTools`.
  Future<McpServerConfig> connect() async {
    final savedEnabled = {for (final t in config.tools) t.name: t.enabled};
    final savedAlwaysAllow = {
      for (final t in config.tools) t.name: t.alwaysAllow,
    };

    // 1. initialize — capture the session id + server identity.
    final initResult = await _request('initialize', {
      'protocolVersion': protocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': clientName, 'version': clientVersion},
    }, captureSession: true);

    // The spec requires the server to echo the revision it agreed to. Left
    // unread, a server that negotiates down looks identical to one that
    // accepted — and the mismatch resurfaces later as an opaque tools/call
    // error pointing at the wrong step.
    final negotiated = '${initResult['protocolVersion'] ?? ''}';
    if (negotiated.isEmpty) {
      throw McpException(
        'MCP "initialize" result from ${config.url} omitted "protocolVersion", '
        'which the spec requires.',
      );
    }
    if (negotiated != protocolVersion) {
      throw McpException(
        'MCP server ${config.url} negotiated protocol "$negotiated", but this '
        'client speaks "$protocolVersion" and implements no other revision. '
        'Pass McpClient(protocolVersion: "$negotiated") once you have verified '
        'compatibility.',
      );
    }
    _negotiatedProtocolVersion = negotiated;

    final serverInfo = initResult['serverInfo'];
    final serverName = serverInfo is Map ? '${serverInfo['name'] ?? ''}' : '';
    final serverVersion = serverInfo is Map
        ? '${serverInfo['version'] ?? ''}'
        : '';

    // 2. notifications/initialized — required by the spec before normal use.
    await _notify('notifications/initialized');

    // 3. tools/list — discover the tools.
    _tools = await _fetchTools(
      savedEnabled: savedEnabled,
      savedAlwaysAllow: savedAlwaysAllow,
    );

    return config.copyWith(
      name: serverName.isNotEmpty ? serverName : null,
      version: serverVersion.isNotEmpty ? serverVersion : null,
      // Hand back an unmodifiable view so the returned config can't be mutated
      // in place through its `tools` list (mirrors the `tools` getter).
      tools: List.unmodifiable(_tools),
    );
  }

  /// Re-run `tools/list` (without re-initializing), refreshing [tools].
  Future<List<McpTool>> listTools() async {
    final savedEnabled = {for (final t in _tools) t.name: t.enabled};
    final savedAlwaysAllow = {for (final t in _tools) t.name: t.alwaysAllow};
    _tools = await _fetchTools(
      savedEnabled: savedEnabled,
      savedAlwaysAllow: savedAlwaysAllow,
    );
    return tools;
  }

  /// Call the MCP tool [toolName] with [arguments] (`tools/call`), returning its
  /// extracted text content. Throws [McpException] on a transport failure;
  /// returns a result with `isError: true` when the server flags the tool error.
  Future<McpToolResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final result = await _request('tools/call', {
      'name': toolName,
      'arguments': arguments,
    });
    return _extractToolResult(result);
  }

  Future<List<McpTool>> _fetchTools({
    required Map<String, bool> savedEnabled,
    required Map<String, bool> savedAlwaysAllow,
  }) async {
    final result = await _request('tools/list', const {});
    final rawTools = result['tools'];
    if (rawTools is! List) return const [];
    return [
      for (final raw in rawTools)
        if (raw is Map)
          McpTool(
            name: '${raw['name'] ?? ''}',
            description: '${raw['description'] ?? ''}',
            inputSchema: raw['inputSchema'] is Map
                ? Map<String, dynamic>.from(raw['inputSchema'] as Map)
                : const {},
            enabled: savedEnabled['${raw['name'] ?? ''}'] ?? true,
            alwaysAllow: savedAlwaysAllow['${raw['name'] ?? ''}'] ?? false,
          ),
    ];
  }

  /// Join every `text` item in a `tools/call` result's `content` array (Gallery's
  /// `filterIsInstance<TextContent>().joinToString("\n")`).
  ///
  /// A spec-conforming result always carries a `content` list. We distinguish:
  ///   * `content` missing or not a list → protocol violation ([McpException]);
  ///   * `content` present but with no `text` items (only image/resource/audio)
  ///     → a clear note rather than an empty success, so the model is never told
  ///     "succeeded" with no output when the tool actually returned something.
  McpToolResult _extractToolResult(Map<String, dynamic> result) {
    final isError = result['isError'] == true;
    final content = result['content'];
    if (content is! List) {
      throw McpException(
        'MCP tool result is missing a "content" array (got: '
        '${content.runtimeType}).',
      );
    }
    final buffer = <String>[];
    final otherTypes = <String>{};
    for (final item in content) {
      if (item is Map && item['type'] == 'text') {
        buffer.add('${item['text'] ?? ''}');
      } else if (item is Map && item['type'] is String) {
        otherTypes.add(item['type'] as String);
      }
    }
    if (buffer.isEmpty && otherTypes.isNotEmpty && !isError) {
      // The tool ran and returned content this client can't render yet — surface
      // that instead of an empty (silently-"succeeded") result.
      return McpToolResult(
        text:
            'MCP tool returned only non-text content '
            '(${otherTypes.join(', ')}), which this client cannot render yet.',
        isError: true,
      );
    }
    return McpToolResult(text: buffer.join('\n'), isError: isError);
  }

  /// Send a JSON-RPC request and return its `result` object. When
  /// [captureSession] is true, store the `Mcp-Session-Id` response header.
  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    bool captureSession = false,
  }) async {
    final id = _nextId++;
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });

    final http.Response response;
    try {
      response = await _http.post(
        Uri.parse(config.url),
        headers: _headers(),
        body: body,
      );
    } catch (e) {
      throw McpException('MCP "$method" request failed: $e');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw McpException(
        'MCP "$method" returned HTTP ${response.statusCode}: ${response.body}',
      );
    }

    if (captureSession) {
      final sid = response.headers['mcp-session-id'];
      if (sid != null && sid.isNotEmpty) _sessionId = sid;
    }

    final message = _parseRpcBody(response, method);
    final error = message['error'];
    if (error is Map) {
      throw McpException('MCP "$method" error: ${error['message'] ?? error}');
    }
    final result = message['result'];
    if (result is! Map) {
      throw McpException('MCP "$method" returned no result object.');
    }
    return Map<String, dynamic>.from(result);
  }

  /// Send a JSON-RPC notification (no `id`, no result expected).
  ///
  /// Not fire-and-forget: `notifications/initialized` is spec-mandatory before
  /// normal operation, and a server that rejected it may legitimately refuse
  /// the `tools/list` that follows. Swallowing the rejection here would send
  /// the debugger to the wrong step.
  Future<void> _notify(String method) async {
    final body = jsonEncode({'jsonrpc': '2.0', 'method': method});
    final http.Response response;
    try {
      response = await _http.post(
        Uri.parse(config.url),
        headers: _headers(),
        body: body,
      );
    } catch (e) {
      throw McpException('MCP notification "$method" failed to send: $e');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw McpException(
        'MCP notification "$method" was rejected with HTTP '
        '${response.statusCode}: ${response.body}',
      );
    }
  }

  /// Parse a JSON-RPC response body that may be plain `application/json` or an
  /// SSE (`text/event-stream`) frame whose `data:` lines carry the JSON message.
  Map<String, dynamic> _parseRpcBody(http.Response response, String method) {
    final contentType = response.headers['content-type'] ?? '';
    final raw = contentType.contains('text/event-stream')
        ? _extractSseJson(response.body)
        : response.body;
    if (raw.trim().isEmpty) {
      throw McpException('MCP "$method" returned an empty body.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      // Keep the MCP-layer invariant that every failure is an McpException, so
      // the executor's `on McpException` mapping always applies (an unguarded
      // FormatException would otherwise escape to the loop's generic catch as an
      // opaque "Unexpected character" message).
      throw McpException('MCP "$method" returned a non-JSON body: $e');
    }
    if (decoded is! Map) {
      throw McpException('MCP "$method" returned a non-object JSON-RPC body.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// Pull the JSON payload out of an SSE stream: the `data:` lines of the LAST
  /// event (the one carrying the JSON-RPC response). A Streamable-HTTP MCP server
  /// may legally emit progress/notification events BEFORE the response in the
  /// same stream, so we must keep only the last event — concatenating all of
  /// them yields multiple JSON objects that `jsonDecode` then rejects. A single
  /// event may itself span multiple `data:` lines (joined with `\n`).
  String _extractSseJson(String body) {
    final current = <String>[];
    var last = <String>[];
    for (final line in const LineSplitter().convert(body)) {
      if (line.startsWith('data:')) {
        current.add(line.substring(5).trimLeft());
      } else if (line.isEmpty && current.isNotEmpty) {
        // Event boundary: this event is complete; it becomes the latest one.
        last = List.of(current);
        current.clear();
      }
    }
    // A trailing event with no blank line after it is still the last event.
    final lastEvent = current.isNotEmpty ? current : last;
    return lastEvent.join('\n');
  }

  Map<String, String> _headers() {
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      // Required on every request after initialize. Without it a stateless
      // server SHOULD assume 2025-03-26 (per the transport spec), so advertising
      // a newer revision in the handshake alone changes nothing on the wire.
      'MCP-Protocol-Version': ?_negotiatedProtocolVersion,
      'Mcp-Session-Id': ?_sessionId,
      ...config.authHeaders,
    };
  }

  /// Close the underlying HTTP client (only if this client created it).
  void close() {
    if (_ownsClient) _http.close();
  }
}
