import 'dart:convert';

import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A MockClient that answers tools/call with the echoed arguments, so the
/// executor's argument-parsing + result-mapping is exercised end to end.
http.Client _callOnlyClient({bool toolError = false}) {
  return MockClient((request) async {
    final decoded = jsonDecode(request.body) as Map<String, dynamic>;
    if (decoded['method'] != 'tools/call') {
      return http.Response('unexpected', 400);
    }
    final args = decoded['params']['arguments'] as Map;
    return http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': decoded['id'],
        'result': {
          'content': [
            {'type': 'text', 'text': 'echo:${jsonEncode(args)}'},
          ],
          'isError': toolError,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// A client pre-loaded with one tool (no network connect needed) so executor
/// tests don't depend on the handshake.
McpClient _clientWithTool({
  required String toolName,
  bool alwaysAllow = false,
  bool enabled = true,
  bool serverEnabled = true,
  http.Client? httpClient,
}) {
  final config = McpServerConfig(
    url: 'https://example.com/mcp',
    enabled: serverEnabled,
    tools: [
      McpTool(name: toolName, enabled: enabled, alwaysAllow: alwaysAllow),
    ],
  );
  return McpClient(config: config, httpClient: httpClient ?? _callOnlyClient());
}

Skill _mcpSkill(String toolName) => Skill(
  name: toolName,
  description: '',
  instructions: '',
  type: SkillType.mcp,
);

void main() {
  group('McpSkillExecutor — probe', () {
    test('canExecuteSkill is true only for mcp skills', () {
      final executor = McpSkillExecutor();
      expect(executor.canExecuteSkill(_mcpSkill('x')), isTrue);
      expect(
        executor.canExecuteSkill(
          Skill(
            name: 'x',
            description: '',
            instructions: '',
            type: SkillType.js,
          ),
        ),
        isFalse,
      );
    });

    test('canExecute (core String contract) bridges to the type', () {
      final executor = McpSkillExecutor();
      expect(executor.canExecute('mcp'), isTrue);
      expect(executor.canExecute('text'), isFalse);
    });
  });

  group('McpSkillExecutor — permission', () {
    test('defaults to deny when no hook is wired', () async {
      final executor = McpSkillExecutor(
        clients: [_clientWithTool(toolName: 'get_weather')],
      );

      final result = await executor.execute(
        _mcpSkill('get_weather'),
        '{"city":"Seattle"}',
      );

      expect(result, isA<ErrorResult>());
      expect((result as ErrorResult).message, contains('Permission denied'));
    });

    test('hook returning true allows the call', () async {
      var asked = false;
      final executor = McpSkillExecutor(
        clients: [_clientWithTool(toolName: 'get_weather')],
        permissionHook: (req) async {
          asked = true;
          expect(req.toolName, 'get_weather');
          expect(req.input, '{"city":"Seattle"}');
          return true;
        },
      );

      final result = await executor.execute(
        _mcpSkill('get_weather'),
        '{"city":"Seattle"}',
      );

      expect(asked, isTrue);
      expect(result, isA<TextResult>());
      expect((result as TextResult).text, 'echo:{"city":"Seattle"}');
    });

    test('hook returning false denies the call', () async {
      final executor = McpSkillExecutor(
        clients: [_clientWithTool(toolName: 'get_weather')],
        permissionHook: (_) async => false,
      );

      final result = await executor.execute(_mcpSkill('get_weather'), '{}');
      expect(result, isA<ErrorResult>());
    });

    test('alwaysAllow tools bypass the permission hook', () async {
      var asked = false;
      final executor = McpSkillExecutor(
        clients: [_clientWithTool(toolName: 'get_weather', alwaysAllow: true)],
        permissionHook: (_) async {
          asked = true;
          return false; // would deny if consulted
        },
      );

      final result = await executor.execute(_mcpSkill('get_weather'), '{}');

      expect(asked, isFalse);
      expect(result, isA<TextResult>());
    });
  });

  group('McpSkillExecutor — routing & errors', () {
    test('unknown tool returns an ErrorResult', () async {
      final executor = McpSkillExecutor(
        clients: [_clientWithTool(toolName: 'get_weather', alwaysAllow: true)],
      );

      final result = await executor.execute(_mcpSkill('does_not_exist'), '{}');
      expect(result, isA<ErrorResult>());
      expect((result as ErrorResult).message, contains('not found'));
    });

    test('disabled tool is not found', () async {
      final executor = McpSkillExecutor(
        clients: [
          _clientWithTool(
            toolName: 'get_weather',
            enabled: false,
            alwaysAllow: true,
          ),
        ],
      );

      final result = await executor.execute(_mcpSkill('get_weather'), '{}');
      expect(result, isA<ErrorResult>());
    });

    test('disabled server is skipped', () async {
      final executor = McpSkillExecutor(
        clients: [
          _clientWithTool(
            toolName: 'get_weather',
            alwaysAllow: true,
            serverEnabled: false,
          ),
        ],
      );

      final result = await executor.execute(_mcpSkill('get_weather'), '{}');
      expect(result, isA<ErrorResult>());
    });

    test('empty input is treated as an empty arguments object', () async {
      final executor = McpSkillExecutor(
        clients: [_clientWithTool(toolName: 'get_weather', alwaysAllow: true)],
      );

      final result = await executor.execute(_mcpSkill('get_weather'), '');
      expect(result, isA<TextResult>());
      expect((result as TextResult).text, 'echo:{}');
    });

    test(
      'non-object input is an ErrorResult before any network call',
      () async {
        final executor = McpSkillExecutor(
          clients: [
            _clientWithTool(toolName: 'get_weather', alwaysAllow: true),
          ],
        );

        final result = await executor.execute(_mcpSkill('get_weather'), '"hi"');
        expect(result, isA<ErrorResult>());
        expect((result as ErrorResult).message, contains('Invalid input'));
      },
    );

    test(
      'a tool-level error maps to ErrorResult with the error text',
      () async {
        final executor = McpSkillExecutor(
          clients: [
            _clientWithTool(
              toolName: 'get_weather',
              alwaysAllow: true,
              httpClient: _callOnlyClient(toolError: true),
            ),
          ],
        );

        final result = await executor.execute(_mcpSkill('get_weather'), '{}');
        expect(result, isA<ErrorResult>());
        expect((result as ErrorResult).message, contains('echo'));
      },
    );
  });

  group('McpSkillExecutor — client management', () {
    test('addClient replaces a client with the same server URL', () {
      final executor = McpSkillExecutor();
      executor.addClient(_clientWithTool(toolName: 'a'));
      executor.addClient(_clientWithTool(toolName: 'b'));

      // Same URL → second add replaces the first.
      expect(executor.clients, hasLength(1));
      expect(executor.clients.single.tools.single.name, 'b');
    });

    test('removeClient drops by URL', () {
      final executor = McpSkillExecutor(
        clients: [_clientWithTool(toolName: 'a')],
      );
      executor.removeClient('https://example.com/mcp');
      expect(executor.clients, isEmpty);
    });
  });
}
