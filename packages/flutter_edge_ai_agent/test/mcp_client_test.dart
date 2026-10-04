import 'dart:convert';

import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A scripted MCP server: returns a canned JSON-RPC reply per `method`, records
/// every request, and lets a test assert on the headers/body it received.
class _FakeMcpServer {
  _FakeMcpServer({
    this.sessionId = 'sess-123',
    this.toolsAsSse = false,
    this.forcedProtocolVersion,
    this.rejectNotification = false,
  });

  /// When set, `initialize` answers with this revision instead of echoing the
  /// client's — i.e. the server negotiates down.
  final String? forcedProtocolVersion;

  /// When true, `notifications/initialized` is answered with HTTP 400 — models
  /// a server that rejects the spec-mandatory notification.
  final bool rejectNotification;

  final String sessionId;
  final bool toolsAsSse;
  final requests = <_RecordedRequest>[];

  http.Client get client => MockClient((request) async {
    final decoded = jsonDecode(request.body) as Map<String, dynamic>;
    final method = decoded['method'] as String;
    requests.add(
      _RecordedRequest(method: method, headers: request.headers, body: decoded),
    );

    switch (method) {
      case 'initialize':
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': decoded['id'],
            'result': {
              // Echo what the client advertised, as the spec requires, unless
              // the test deliberately forces a downgrade.
              'protocolVersion':
                  forcedProtocolVersion ?? decoded['params']['protocolVersion'],
              'serverInfo': {'name': 'fake-mcp', 'version': '9.9'},
            },
          }),
          200,
          headers: {
            'content-type': 'application/json',
            'mcp-session-id': sessionId,
          },
        );
      case 'notifications/initialized':
        return rejectNotification
            ? http.Response('session expired', 400)
            : http.Response('', 202);
      case 'tools/list':
        final payload = jsonEncode({
          'jsonrpc': '2.0',
          'id': decoded['id'],
          'result': {
            'tools': [
              {
                'name': 'get_weather',
                'description': 'Weather for a city.',
                'inputSchema': {
                  'type': 'object',
                  'properties': {
                    'city': {'type': 'string'},
                  },
                },
              },
            ],
          },
        });
        if (toolsAsSse) {
          return http.Response(
            'event: message\ndata: $payload\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response(
          payload,
          200,
          headers: {'content-type': 'application/json'},
        );
      case 'tools/call':
        final args = decoded['params']['arguments'] as Map;
        final city = args['city'] ?? 'unknown';
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': decoded['id'],
            'result': {
              'content': [
                {'type': 'text', 'text': 'Sunny in $city'},
              ],
              'isError': false,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      default:
        return http.Response('not found', 404);
    }
  });
}

class _RecordedRequest {
  _RecordedRequest({
    required this.method,
    required this.headers,
    required this.body,
  });
  final String method;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

void main() {
  const config = McpServerConfig(url: 'https://example.com/mcp');

  group('McpClient.connect', () {
    test('runs initialize → notifications/initialized → tools/list', () async {
      final server = _FakeMcpServer();
      final client = McpClient(config: config, httpClient: server.client);

      final connected = await client.connect();

      expect(server.requests.map((r) => r.method), [
        'initialize',
        'notifications/initialized',
        'tools/list',
      ]);
      expect(connected.name, 'fake-mcp');
      expect(connected.version, '9.9');
      expect(connected.tools.single.name, 'get_weather');
      expect(client.tools.single.description, 'Weather for a city.');
    });

    test('captures Mcp-Session-Id and echoes it on later requests', () async {
      final server = _FakeMcpServer(sessionId: 'abc-789');
      final client = McpClient(config: config, httpClient: server.client);

      await client.connect();

      expect(client.sessionId, 'abc-789');
      final toolsListReq = server.requests.firstWhere(
        (r) => r.method == 'tools/list',
      );
      expect(toolsListReq.headers['mcp-session-id'], 'abc-789');
    });

    test('sends the spec-required Accept header', () async {
      final server = _FakeMcpServer();
      final client = McpClient(config: config, httpClient: server.client);

      await client.connect();

      final accept = server.requests.first.headers['accept'] ?? '';
      expect(accept, contains('application/json'));
      expect(accept, contains('text/event-stream'));
    });

    test('parses a tools/list delivered as an SSE frame', () async {
      final server = _FakeMcpServer(toolsAsSse: true);
      final client = McpClient(config: config, httpClient: server.client);

      final connected = await client.connect();

      expect(connected.tools.single.name, 'get_weather');
    });

    test('preserves enabled/alwaysAllow across a reconnect', () async {
      final server = _FakeMcpServer();
      final seeded = config.copyWith(
        tools: const [McpTool(name: 'get_weather', alwaysAllow: true)],
      );
      final client = McpClient(config: seeded, httpClient: server.client);

      final connected = await client.connect();

      expect(connected.tools.single.alwaysAllow, isTrue);
    });

    // The advertised revision is the one thing an audience of spec authors can
    // check live, so it is pinned by a test rather than left to drift.
    test('advertises the current protocol revision by default', () async {
      final server = _FakeMcpServer();
      final client = McpClient(config: config, httpClient: server.client);

      expect(client.protocolVersion, '2025-11-25');

      await client.connect();

      final initialize = server.requests.first;
      expect(initialize.method, 'initialize');
      expect(initialize.body['params']['protocolVersion'], '2025-11-25');
      expect(client.negotiatedProtocolVersion, '2025-11-25');
    });

    test(
      'sends MCP-Protocol-Version on every request after initialize',
      () async {
        // Without this header a stateless server MUST assume 2025-03-26, so the
        // advertised revision alone changes nothing on the wire.
        final server = _FakeMcpServer();
        final client = McpClient(config: config, httpClient: server.client);

        await client.connect();

        final initialize = server.requests.first;
        expect(
          initialize.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('mcp-protocol-version')),
          reason: 'the revision is not yet negotiated during initialize',
        );

        final toolsList = server.requests.firstWhere(
          (r) => r.method == 'tools/list',
        );
        final header = toolsList.headers.entries
            .firstWhere((e) => e.key.toLowerCase() == 'mcp-protocol-version')
            .value;
        expect(header, '2025-11-25');
      },
    );

    test('throws when the server negotiates a different revision', () async {
      final server = _FakeMcpServer(forcedProtocolVersion: '2025-06-18');
      final client = McpClient(config: config, httpClient: server.client);

      await expectLater(
        client.connect(),
        throwsA(
          isA<McpException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('2025-06-18'), contains('2025-11-25')),
          ),
        ),
      );
    });

    test('connect() throws when notifications/initialized is rejected', () async {
      // The notification is spec-mandatory before tools/list; a server that
      // rejects it may then refuse tools/list, so the failure must surface here
      // rather than be swallowed (which would send the debugger to the wrong
      // request). tools/list stays valid, so a reverted swallow would let
      // connect() SUCCEED — the message assertion pins the notification failure.
      final server = _FakeMcpServer(rejectNotification: true);
      final client = McpClient(config: config, httpClient: server.client);

      await expectLater(
        client.connect(),
        throwsA(
          isA<McpException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('notifications/initialized'), contains('400')),
          ),
        ),
      );
    });
  });

  group('McpClient.callTool', () {
    test('extracts joined text content from the result', () async {
      final server = _FakeMcpServer();
      final client = McpClient(config: config, httpClient: server.client);
      await client.connect();

      final result = await client.callTool('get_weather', {'city': 'Seattle'});

      expect(result.isError, isFalse);
      expect(result.text, 'Sunny in Seattle');
    });

    test('surfaces a JSON-RPC error as an McpException', () async {
      final errClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'error': {'code': -32000, 'message': 'boom'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = McpClient(config: config, httpClient: errClient);

      expect(
        () => client.callTool('get_weather', const {}),
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            contains('boom'),
          ),
        ),
      );
    });

    test('non-2xx HTTP is an McpException', () async {
      final errClient = MockClient(
        (request) async => http.Response('nope', 500),
      );
      final client = McpClient(config: config, httpClient: errClient);

      expect(
        () => client.callTool('get_weather', const {}),
        throwsA(isA<McpException>()),
      );
    });

    test('a tool flagged isError returns isError:true (not a throw)', () async {
      final errToolClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'content': [
                {'type': 'text', 'text': 'city is required'},
              ],
              'isError': true,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = McpClient(config: config, httpClient: errToolClient);

      final result = await client.callTool('get_weather', const {});
      expect(result.isError, isTrue);
      expect(result.text, 'city is required');
    });

    test('SSE with a pre-response event uses the LAST event, not all', () async {
      // Regression: a progress/notification SSE frame before the JSON-RPC
      // response must not be concatenated with it (which made jsonDecode throw).
      final responseJson = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'content': [
            {'type': 'text', 'text': 'Sunny in Seattle'},
          ],
        },
      });
      final progressJson = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/progress',
        'params': {'progress': 1},
      });
      final sseClient = MockClient((request) async {
        return http.Response(
          'event: message\ndata: $progressJson\n\n'
          'event: message\ndata: $responseJson\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final client = McpClient(config: config, httpClient: sseClient);

      final result = await client.callTool('get_weather', const {});
      expect(result.isError, isFalse);
      expect(result.text, 'Sunny in Seattle');
    });

    test('non-text-only content is surfaced as an error, not empty success', () {
      // Regression M3: a tool that returns only image/resource content must not
      // report an empty success — the output would silently vanish.
      final imageOnlyClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'content': [
                {'type': 'image', 'data': 'iVBOR…', 'mimeType': 'image/png'},
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = McpClient(config: config, httpClient: imageOnlyClient);

      return client.callTool('make_chart', const {}).then((result) {
        expect(result.isError, isTrue);
        expect(result.text, contains('non-text content'));
      });
    });

    test('a result with no content array is a protocol-violation error', () {
      // Regression M4: missing/non-list content must be an McpException, not an
      // empty success indistinguishable from a tool that returned nothing.
      final noContentClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {'isError': false},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = McpClient(config: config, httpClient: noContentClient);

      return expectLater(
        () => client.callTool('get_weather', const {}),
        throwsA(isA<McpException>()),
      );
    });

    test(
      'a non-JSON 2xx body throws an McpException (not a FormatException)',
      () {
        // Regression L4: keep the all-failures-are-McpException invariant.
        final badJsonClient = MockClient((request) async {
          return http.Response(
            '<html>gateway error</html>',
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = McpClient(config: config, httpClient: badJsonClient);

        return expectLater(
          () => client.callTool('get_weather', const {}),
          throwsA(isA<McpException>()),
        );
      },
    );
  });
}
