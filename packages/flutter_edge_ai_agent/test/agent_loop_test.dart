import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show
        FunctionCallResponse,
        InferenceChat,
        Message,
        MessageType,
        ModelResponse,
        ParallelFunctionCallResponse,
        TextResponse,
        ThinkingResponse;
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A scriptable fake [InferenceChat]: yields the next queued turn's token/call
/// stream per [generateChatResponseAsync] call and records every
/// [addQueryChunk] message (so a test can assert what was fed back to the
/// model). Subclasses the real [InferenceChat] (mirrors the genkit
/// `FakeInferenceChat` pattern) so no real session is created.
class _FakeAgentChat extends InferenceChat {
  /// Flat form: one [ModelResponse] per turn (each becomes a single-element
  /// token stream). Keeps every pre-streaming test constructing the fake the
  /// same way — `[a, b, c]` is still three separate turns.
  _FakeAgentChat(
    List<ModelResponse> responses, {
    super.supportImage,
    super.supportAudio,
  }) : _turns = [
         for (final r in responses) [r],
       ],
       _errorAfterTurns = const {},
       super(sessionCreator: null, maxTokens: 1024);

  /// Streaming form: each inner list is one turn's ORDERED token/call stream,
  /// so a turn can emit several [TextResponse] tokens (and/or a call). This is
  /// what proves the loop streams token-by-token like VoiceSession.
  /// [errorAfterTurns] names turn indices whose stream THROWS after yielding its
  /// responses — models a native decode error mid-stream, AFTER a tool-call was
  /// already parsed + committed to history by generateChatResponseAsync.
  _FakeAgentChat.turns(
    this._turns, {
    this._errorAfterTurns = const {},
    super.supportAudio,
  }) : super(sessionCreator: null, maxTokens: 1024);

  final List<List<ModelResponse>> _turns;
  final Set<int> _errorAfterTurns;
  int _turn = 0;

  /// Every message fed back into the chat (user message + tool responses).
  final List<Message> received = [];

  /// One increment per model generation (per [generateChatResponseAsync] call).
  int generateCallCount = 0;

  @override
  Future<void> initSession() async {}

  @override
  Future<void> addQueryChunk(
    Message message, [
    bool noTool = false,
    bool prefix = false,
  ]) async {
    received.add(message);
  }

  /// The loop drives the STREAMING API (parity with VoiceSession). Yields this
  /// turn's scripted token/call stream; a default terminal text turn keeps an
  /// over-eager loop from running past the script.
  @override
  Stream<ModelResponse> generateChatResponseAsync() async* {
    generateCallCount++;
    if (_turn >= _turns.length) {
      yield const TextResponse('done');
      return;
    }
    final turnIndex = _turn++;
    for (final response in _turns[turnIndex]) {
      yield response;
    }
    if (_errorAfterTurns.contains(turnIndex)) {
      throw StateError('native decode failed mid-stream');
    }
  }

  /// The loop must NEVER fall back to the blocking API — streaming was the whole
  /// point of the refactor. Fail loudly (and permanently guard the regression)
  /// if it ever does.
  @override
  Future<ModelResponse> generateChatResponse() => throw UnimplementedError(
    'AgentLoop must drive generateChatResponseAsync (streaming), not the '
    'blocking generateChatResponse.',
  );

  @override
  Future<void> close() async {}

  /// The tool-response messages fed back (excludes the initial user message).
  List<Message> get toolResponses =>
      received.where((m) => m.type == MessageType.toolResponse).toList();

  /// The plain user messages: the turn's own and any nudge the loop added.
  /// (A tool response is a user-side message too, so `isUser` cannot tell.)
  List<Message> get userMessages =>
      received.where((m) => m.type == MessageType.text).toList();
}

/// A fake executor that handles a single [SkillType] and returns a preset
/// [SkillResult], recording every call.
class _FakeExecutor extends SkillExecutor {
  _FakeExecutor(
    this._type, {
    SkillResult? result,
    this.priority = 0,
    this.name = 'fake',
  }) : _result = result ?? const TextResult('ok');

  final SkillType _type;
  final SkillResult _result;

  @override
  final String name;

  @override
  final int priority;

  final List<({Skill skill, String dataJson, String? secret})> calls = [];

  @override
  bool canExecuteSkill(Skill skill) => skill.type == _type;

  @override
  Future<SkillResult> execute(
    Skill skill,
    String dataJson, {
    String? secret,
  }) async {
    calls.add((skill: skill, dataJson: dataJson, secret: secret));
    return _result;
  }
}

Skill _jsSkill({String name = 'calculate-hash'}) => Skill(
  name: name,
  description: 'Calculate the hash of a given text.',
  instructions: 'Call the `run_js` tool with script name index.html.',
  type: SkillType.js,
);

FunctionCallResponse _loadSkill(String name) =>
    FunctionCallResponse(name: 'loadSkill', args: {'skillName': name});

FunctionCallResponse _runSkill(String name, {String data = '{}'}) =>
    FunctionCallResponse(
      name: 'runSkill',
      args: {'skillName': name, 'scriptName': 'index.html', 'data': data},
    );

Skill _textSkill(String name) => Skill(
  name: name,
  description: 'Suggest what to pack for a trip.',
  instructions: 'List what to pack. Answer the user directly.',
  type: SkillType.textOnly,
);

Skill _intentSkill(String name, {bool requireSecret = false}) => Skill(
  name: name,
  description: 'Report the current local date and time.',
  instructions: 'Call the `run_intent` tool with get_current_date_and_time.',
  type: SkillType.intent,
  metadata: SkillMetadata(requireSecret: requireSecret),
);

FunctionCallResponse _runIntent(Map<String, dynamic> args) =>
    FunctionCallResponse(name: 'runIntent', args: args);

/// A real [McpSkillExecutor] over one connected server that exports
/// [toolName] (pre-allowed, so no permission hook). Its `tools/call` answers
/// `<tool>:<arguments JSON>`, so a test sees which tool ran with what.
McpSkillExecutor _echoMcpExecutor(String toolName) {
  final server = MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final params = body['params'] as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': body['id'],
        'result': {
          'content': [
            {
              'type': 'text',
              'text': '${params['name']}:${jsonEncode(params['arguments'])}',
            },
          ],
          'isError': false,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return McpSkillExecutor(
    clients: [
      McpClient(
        config: McpServerConfig(
          url: 'https://example.com/mcp',
          tools: [McpTool(name: toolName, alwaysAllow: true)],
        ),
        httpClient: server,
      ),
    ],
  );
}

void main() {
  group('AgentLoop — happy path', () {
    test(
      'dispatches loadSkill then runSkill, feeds both back, ends on text',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final executor = _FakeExecutor(
          SkillType.js,
          result: const TextResult('hash=abc123'),
        );
        final chat = _FakeAgentChat([
          _loadSkill('calculate-hash'),
          _runSkill('calculate-hash', data: '{"text":"hi"}'),
          const TextResponse('The hash is abc123.'),
        ]);

        final loop = AgentLoop(registry: registry, executors: [executor]);
        final events = await loop.run(chat, 'hash of hi').toList();

        // Event sequence: SkillLoad -> ToolCall -> ToolResult -> Text -> Done.
        expect(events[0], isA<SkillLoadEvent>());
        expect((events[0] as SkillLoadEvent).found, isTrue);
        expect(events[1], isA<ToolCallEvent>());
        expect((events[1] as ToolCallEvent).toolName, 'runSkill');
        // The event's args are an unmodifiable view of the loop's parsed args.
        expect(
          () => (events[1] as ToolCallEvent).args['x'] = 1,
          throwsUnsupportedError,
        );
        expect(events[2], isA<ToolResultEvent>());
        expect(events.whereType<DoneEvent>().single.text, contains('abc123'));

        // The executor ran once with the model-supplied data + targeted skill.
        expect(executor.calls, hasLength(1));
        expect(executor.calls.single.dataJson, '{"text":"hi"}');
        expect(executor.calls.single.skill.name, 'calculate-hash');

        // Three generations: loadSkill, runSkill, final text.
        expect(chat.generateCallCount, 3);

        // Both tool calls got a tool-response fed back.
        final fed = chat.toolResponses;
        expect(fed, hasLength(2));
        expect(fed[0].toolName, 'loadSkill');
        expect(fed[0].text, contains('run_js')); // full instructions returned
        expect(fed[1].toolName, 'runSkill');
        expect(fed[1].text, contains('hash=abc123'));
      },
    );

    test('first message fed to chat is the user message', () async {
      final registry = SkillRegistry();
      final chat = _FakeAgentChat([const TextResponse('hi there')]);
      final loop = AgentLoop(registry: registry, executors: const []);

      await loop.run(chat, 'hello').toList();

      expect(chat.received.first.isUser, isTrue);
      expect(chat.received.first.text, 'hello');
    });
  });

  group('AgentLoop — termination', () {
    test('terminates on a plain text response (no tools)', () async {
      final registry = SkillRegistry();
      final chat = _FakeAgentChat([const TextResponse('just chatting')]);
      final loop = AgentLoop(registry: registry, executors: const []);

      final events = await loop.run(chat, 'hey').toList();

      expect(events.last, isA<DoneEvent>());
      expect((events.last as DoneEvent).text, 'just chatting');
      expect(chat.generateCallCount, 1);
    });

    test('respects maxIterations on a runaway tool loop', () async {
      final registry = SkillRegistry()..add(_jsSkill(), selected: true);
      final executor = _FakeExecutor(SkillType.js);
      // The model keeps calling runSkill forever — never a text answer.
      final chat = _FakeAgentChat(
        List.generate(50, (_) => _runSkill('calculate-hash')),
      );

      final loop = AgentLoop(
        registry: registry,
        executors: [executor],
        maxIterations: 4,
      );
      final events = await loop.run(chat, 'spin').toList();

      expect(events.last, isA<MaxIterationsEvent>());
      expect((events.last as MaxIterationsEvent).iterations, 4);
      // Exactly maxIterations generations, no more.
      expect(chat.generateCallCount, 4);
    });
  });

  group('AgentLoop — isCancelled', () {
    test(
      'run stops early when isCancelled flips true (no further generations)',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final chat = _FakeAgentChat([
          _runSkill('calculate-hash'),
          const TextResponse('should never be reached'),
        ]);
        final loop = AgentLoop(
          registry: registry,
          executors: [_FakeExecutor(SkillType.js)],
        );

        var cancel = false;
        final events = <AgentEvent>[];
        await for (final e in loop.run(chat, 'hi', isCancelled: () => cancel)) {
          events.add(e);
          cancel = true; // flip after the first emitted event
        }

        expect(
          chat.generateCallCount,
          1,
          reason: 'no second generation after cancel',
        );
        expect(events.whereType<DoneEvent>(), isEmpty);
        expect(events.whereType<MaxIterationsEvent>(), isEmpty);
      },
    );

    test(
      'run without isCancelled behaves exactly as before (text -> DoneEvent)',
      () async {
        final registry = SkillRegistry();
        final chat = _FakeAgentChat([const TextResponse('hello')]);
        final loop = AgentLoop(registry: registry, executors: const []);
        final events = await loop.run(chat, 'hi').toList();
        expect(events.whereType<DoneEvent>().single.text, 'hello');
      },
    );
  });

  group('AgentLoop — parallel calls', () {
    test(
      'handles a ParallelFunctionCallResponse: dispatches every call',
      () async {
        final registry = SkillRegistry()
          ..add(_jsSkill(name: 'a'), selected: true)
          ..add(_jsSkill(name: 'b'), selected: true);
        final executor = _FakeExecutor(
          SkillType.js,
          result: const TextResult('done'),
        );
        final chat = _FakeAgentChat([
          ParallelFunctionCallResponse(
            calls: [
              _runSkill('a', data: '{"i":1}'),
              _runSkill('b', data: '{"i":2}'),
            ],
          ),
          const TextResponse('both done'),
        ]);

        final loop = AgentLoop(registry: registry, executors: [executor]);
        final events = await loop.run(chat, 'do both').toList();

        // Both parallel calls ran, each with its own data.
        expect(executor.calls, hasLength(2));
        expect(executor.calls[0].dataJson, '{"i":1}');
        expect(executor.calls[1].dataJson, '{"i":2}');

        // Two tool responses fed back, then the loop ends on text.
        expect(chat.toolResponses, hasLength(2));
        expect(events.whereType<ToolResultEvent>(), hasLength(2));
        expect(events.last, isA<DoneEvent>());
      },
    );
  });

  group('AgentLoop — loadSkill lookup', () {
    test(
      'unknown skill name emits an error event and feeds a failed status',
      () async {
        final registry = SkillRegistry(); // empty
        final chat = _FakeAgentChat([
          _loadSkill('nope'),
          const TextResponse('I could not find that skill.'),
        ]);

        final loop = AgentLoop(registry: registry, executors: const []);
        final events = await loop.run(chat, 'load nope').toList();

        final load = events.whereType<SkillLoadEvent>().single;
        expect(load.found, isFalse);
        // The miss must surface as a real error event, not be fed into the
        // skill_instructions field as if it were content.
        final error = events.whereType<AgentErrorEvent>().single;
        expect(error.message, contains('not found'));
        final fed = chat.toolResponses.single;
        expect(fed.toolName, 'loadSkill');
        expect(fed.text, contains('failed'));
        expect(fed.text, contains('not found'));
        // Must NOT be fed as if it were real instructions.
        expect(fed.text, isNot(contains('skill_instructions')));
        expect(events.last, isA<DoneEvent>());
      },
    );
  });

  group('AgentLoop — executor selection', () {
    test(
      'no executor for the call feeds an error back and continues',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        // Only an intent executor registered — cannot handle a JS skill.
        final intentExecutor = _FakeExecutor(SkillType.intent);
        final chat = _FakeAgentChat([
          _runSkill('calculate-hash'),
          const TextResponse('sorry, cannot run that'),
        ]);

        final loop = AgentLoop(registry: registry, executors: [intentExecutor]);
        final events = await loop.run(chat, 'run it').toList();

        expect(intentExecutor.calls, isEmpty);
        expect(events.whereType<AgentErrorEvent>(), isNotEmpty);
        final fed = chat.toolResponses.single;
        expect(fed.text, contains('No executor available'));
        expect(events.last, isA<DoneEvent>());
      },
    );

    test('higher-priority executor wins the probe-chain', () async {
      final registry = SkillRegistry()..add(_jsSkill(), selected: true);
      final low = _FakeExecutor(
        SkillType.js,
        result: const TextResult('low'),
        name: 'low',
      );
      final high = _FakeExecutor(
        SkillType.js,
        result: const TextResult('high'),
        priority: 10,
        name: 'high',
      );
      final chat = _FakeAgentChat([
        _runSkill('calculate-hash'),
        const TextResponse('ok'),
      ]);

      // Registered low-first; high must still win on priority.
      final loop = AgentLoop(registry: registry, executors: [low, high]);
      await loop.run(chat, 'go').toList();

      expect(high.calls, hasLength(1));
      expect(low.calls, isEmpty);
      expect(chat.toolResponses.single.text, contains('high'));
    });
  });

  group('AgentLoop — direct skill-name call guard', () {
    // Small models (esp. on the web decoder) sometimes call a skill by name as
    // if it were a tool — e.g. `calculate-hash{text:...}` — instead of the
    // two-stage `loadSkill` then `run_js`. That skips the skill's instructions
    // (which say WHICH executor to use), so we must NOT run it directly. Mirror
    // Gallery's `guardMissingEntityWithSkillFallback`: when the unknown tool is
    // a known skill, feed back a hint that steers the model to loadSkill.
    test(
      'calling a known skill directly hints the model to load it as a skill',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final chat = _FakeAgentChat([
          const FunctionCallResponse(
            name: 'calculate-hash',
            args: {'text': 'hello'},
          ),
          const TextResponse('ok'),
        ]);

        final loop = AgentLoop(registry: registry, executors: const []);
        final events = await loop.run(chat, 'hash hello').toList();

        // Must NOT execute directly (contract stays two-stage).
        final error = events.whereType<AgentErrorEvent>().single;
        expect(error.toolName, 'calculate-hash');
        final fed = chat.toolResponses.single;
        expect(fed.text, contains('failed'));
        // The hint must name loadSkill so the model can self-correct.
        expect(fed.text, contains('loadSkill'));
        expect(fed.text, contains('calculate-hash'));
        expect(events.last, isA<DoneEvent>());
      },
    );

    test(
      'an unknown tool that is NOT a skill just reports unknown tool',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final chat = _FakeAgentChat([
          const FunctionCallResponse(name: 'totally-made-up', args: {}),
          const TextResponse('ok'),
        ]);

        final loop = AgentLoop(registry: registry, executors: const []);
        final events = await loop.run(chat, 'do x').toList();

        final fed = chat.toolResponses.single;
        expect(fed.text, contains('failed'));
        expect(fed.text, isNot(contains('loadSkill')));
        expect(events.last, isA<DoneEvent>());
      },
    );
  });

  group('AgentLoop — SKILL.md tool-name aliases (web)', () {
    // The bundled SKILL.md files (verbatim from Gallery) tell the model to
    // "Call the `run_js` / `run_intent` tool", but the tool DECLARATIONS are
    // named runSkill / runIntent / runMcp. Native decoders take the name from
    // the structured declaration (runSkill — works); the web decoder follows
    // the SKILL.md text literally and calls `run_js`, which the switch didn't
    // know → "unknown tool run_js". Accept the SKILL.md spelling as an alias.
    test('run_js is dispatched to the JS executor (like runSkill)', () async {
      final registry = SkillRegistry()..add(_jsSkill(), selected: true);
      final executor = _FakeExecutor(
        SkillType.js,
        result: const TextResult('hash=abc123'),
      );
      final chat = _FakeAgentChat([
        _loadSkill('calculate-hash'),
        // The model uses the SKILL.md spelling `run_js`, not `runSkill`.
        const FunctionCallResponse(
          name: 'run_js',
          args: {
            'skillName': 'calculate-hash',
            'scriptName': 'index.html',
            'data': '{"text":"hi"}',
          },
        ),
        const TextResponse('The hash is abc123.'),
      ]);

      final loop = AgentLoop(registry: registry, executors: [executor]);
      final events = await loop.run(chat, 'hash of hi').toList();

      // It must run the JS executor, NOT fall through to "unknown tool".
      expect(executor.calls, hasLength(1));
      expect(executor.calls.single.dataJson, '{"text":"hi"}');
      expect(events.whereType<ToolResultEvent>(), isNotEmpty);
      expect(
        events.whereType<AgentErrorEvent>().where(
          (e) => e.message.contains('Unknown tool'),
        ),
        isEmpty,
      );
      expect(events.whereType<DoneEvent>().single.text, contains('abc123'));
      // The tool-response is paired with the model's ORIGINAL call name (run_js),
      // not the internally-normalized runSkill — on the success path too.
      expect(
        chat.toolResponses.where((m) => m.toolName == 'run_js'),
        hasLength(1),
      );
    });

    test('run_intent is dispatched to the intent executor', () async {
      final registry = SkillRegistry()
        ..add(
          Skill(
            name: 'open-map',
            description: 'Open a map.',
            instructions: 'Call the `run_intent` tool.',
            type: SkillType.intent,
          ),
          selected: true,
        );
      final executor = _FakeExecutor(
        SkillType.intent,
        result: const TextResult('opened'),
      );
      final chat = _FakeAgentChat([
        _loadSkill('open-map'),
        const FunctionCallResponse(
          name: 'run_intent',
          args: {'skillName': 'open-map', 'parameters': '{}'},
        ),
        const TextResponse('done'),
      ]);

      final loop = AgentLoop(registry: registry, executors: [executor]);
      final events = await loop.run(chat, 'open map').toList();

      expect(executor.calls, hasLength(1));
      expect(
        events.whereType<AgentErrorEvent>().where(
          (e) => e.message.contains('Unknown tool'),
        ),
        isEmpty,
      );
    });

    // Gallery's own names for the JS and MCP tools, which a SKILL.md written
    // for Gallery tells the model to call.
    test('runJs is dispatched to the JS executor', () async {
      final registry = SkillRegistry()..add(_jsSkill(), selected: true);
      final executor = _FakeExecutor(
        SkillType.js,
        result: const TextResult('hash=abc123'),
      );
      final chat = _FakeAgentChat([
        _loadSkill('calculate-hash'),
        const FunctionCallResponse(
          name: 'runJs',
          args: {'skillName': 'calculate-hash', 'data': '{"text":"hi"}'},
        ),
        const TextResponse('The hash is abc123.'),
      ]);

      final loop = AgentLoop(registry: registry, executors: [executor]);
      final events = await loop.run(chat, 'hash of hi').toList();

      expect(executor.calls.single.skill.name, 'calculate-hash');
      expect(executor.calls.single.dataJson, '{"text":"hi"}');
      expect(events.whereType<AgentErrorEvent>(), isEmpty);
      expect(
        chat.toolResponses.where((m) => m.toolName == 'runJs'),
        hasLength(1),
      );
      expect((events.last as DoneEvent).text, 'The hash is abc123.');
    });

    test('runMcpTool is dispatched to the MCP executor', () async {
      final chat = _FakeAgentChat([
        const FunctionCallResponse(
          name: 'runMcpTool',
          args: {'toolName': 'get_forecast', 'input': '{"city":"Paris"}'},
        ),
        const TextResponse('Sunny.'),
      ]);

      final loop = AgentLoop(
        registry: SkillRegistry(),
        executors: [_echoMcpExecutor('get_forecast')],
      );
      final events = await loop.run(chat, 'weather in Paris?').toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect((result as TextResult).text, 'get_forecast:{"city":"Paris"}');
      expect(events.whereType<AgentErrorEvent>(), isEmpty);
      expect(
        chat.toolResponses.where((m) => m.toolName == 'runMcpTool'),
        hasLength(1),
      );
    });
  });

  group('AgentLoop — run_js without skillName is guided, not guessed', () {
    // The web decoder loads a skill (loadSkill "calculate-hash") then calls
    // run_js WITHOUT repeating skillName in the args. We must NOT guess/execute
    // a synthetic skill named after the tool ("runSkill" → 404). Instead, feed
    // back a clear error naming skillName so the model self-corrects — the same
    // error-feedback strategy as the direct-skill-call guard.
    test(
      'run_js with no skillName feeds back a skillName hint and does not execute',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final executor = _FakeExecutor(
          SkillType.js,
          result: const TextResult('hash=abc123'),
        );
        final chat = _FakeAgentChat([
          _loadSkill('calculate-hash'),
          // run_js with NO skillName / toolName arg — just the data.
          const FunctionCallResponse(
            name: 'run_js',
            args: {'scriptName': 'index.html', 'data': '{"text":"hi"}'},
          ),
          const TextResponse('sorry, I need the skill name'),
        ]);

        final loop = AgentLoop(registry: registry, executors: [executor]);
        final events = await loop.run(chat, 'hash of hi').toList();

        // The executor must NOT run — we didn't guess a skill.
        expect(executor.calls, isEmpty);
        // A real error event hinting skillName.
        final error = events.whereType<AgentErrorEvent>().single;
        expect(error.message, contains('skillName'));
        // Two tool responses fed back: loadSkill (instructions) + the run call
        // (error). Core feeds the response paired with the model's ORIGINAL call
        // name (`run_js`) — the alias is normalized only internally, for executor
        // selection, not in the fed-back tool-response.
        final fed = chat.toolResponses.last;
        expect(fed.toolName, 'run_js');
        expect(fed.text, contains('failed'));
        expect(fed.text, contains('skillName'));
        // Must NOT have tried a synthetic `runSkill` asset path.
        expect(fed.text, isNot(contains('runSkill')));
        expect(events.last, isA<DoneEvent>());
      },
    );
  });

  group('AgentLoop — secrets', () {
    test(
      'require-secret skill gets its secret injected, never in the prompt',
      () async {
        final secretSkill = Skill(
          name: 'weather',
          description: 'Get weather.',
          instructions: 'Call the `run_js` tool.',
          type: SkillType.js,
          metadata: const SkillMetadata(requireSecret: true),
        );
        final registry = SkillRegistry()..add(secretSkill, selected: true);
        final executor = _FakeExecutor(SkillType.js);
        final secrets = SecretStore()..set('weather', 'sk-secret-123');
        final chat = _FakeAgentChat([
          _runSkill('weather'),
          const TextResponse('it is sunny'),
        ]);

        final loop = AgentLoop(
          registry: registry,
          executors: [executor],
          secretStore: secrets,
        );
        await loop.run(chat, 'weather?').toList();

        // Secret reached the executor...
        expect(executor.calls.single.secret, 'sk-secret-123');
        // ...but never appeared in anything sent to the model.
        for (final m in chat.received) {
          expect(m.text, isNot(contains('sk-secret-123')));
        }
      },
    );
  });

  group('AgentLoop — image / webview results', () {
    test(
      'image result surfaces an ImageResult event + non-leaky tool response',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final executor = _FakeExecutor(
          SkillType.js,
          result: ImageResult(Uint8List.fromList([1, 2, 3])),
        );
        final chat = _FakeAgentChat([
          _runSkill('calculate-hash'),
          const TextResponse('here is your image'),
        ]);

        final loop = AgentLoop(registry: registry, executors: [executor]);
        final events = await loop.run(chat, 'make an image').toList();

        final result = events.whereType<ToolResultEvent>().single.result;
        expect(result, isA<ImageResult>());
        // The fed-back text describes the image rather than dumping bytes.
        expect(chat.toolResponses.single.text, contains('image'));
      },
    );
  });

  group('AgentLoop — empty answer after loadSkill', () {
    test(
      'one nudge after an empty answer, then the text ends the turn',
      () async {
        final registry = SkillRegistry()
          ..add(_textSkill('packing-list'), selected: true);
        final chat = _FakeAgentChat.turns([
          [_loadSkill('packing-list')],
          [const TextResponse(' \n')], // only whitespace: empty after trimming
          [const TextResponse('Pack a towel.')],
        ]);
        final loop = AgentLoop(registry: registry, executors: const []);

        final events = await loop.run(chat, 'what should I pack?').toList();

        final retry = events.whereType<EmptyAnswerRetryEvent>().single;
        expect(retry.skillName, 'packing-list');
        expect(retry.attempt, 1);
        expect(retry.nudge, defaultEmptyAfterSkillNudge);
        // The retry is announced before the answer that follows it.
        expect(
          events.indexOf(retry),
          lessThan(events.indexWhere((e) => e is DoneEvent)),
        );
        final done = events.whereType<DoneEvent>().single;
        expect(done, isNot(isA<EmptyAnswerEvent>()));
        // Only the retried generation's text: the whitespace is not part of it.
        expect(done.text, 'Pack a towel.');
        expect(events.last, same(done));
        expect(chat.generateCallCount, 3);
        // The nudge went to the same chat as a user message, after the
        // loadSkill result and before the third generation.
        expect(chat.received, hasLength(3));
        expect(chat.received[1].toolName, 'loadSkill');
        expect(chat.received[2].isUser, isTrue);
        expect(chat.received[2].text, defaultEmptyAfterSkillNudge);
      },
    );

    test('still empty after the retries → EmptyAnswerEvent', () async {
      final registry = SkillRegistry()
        ..add(_textSkill('packing-list'), selected: true);
      final chat = _FakeAgentChat.turns([
        [_loadSkill('packing-list')],
        <ModelResponse>[],
        <ModelResponse>[],
      ]);
      final loop = AgentLoop(registry: registry, executors: const []);

      final events = await loop.run(chat, 'what should I pack?').toList();

      expect(events.whereType<EmptyAnswerRetryEvent>(), hasLength(1));
      final done = events.whereType<DoneEvent>().single;
      expect(done, isA<EmptyAnswerEvent>());
      expect((done as EmptyAnswerEvent).skillName, 'packing-list');
      expect(done.text, '');
      expect(events.last, same(done));
      expect(chat.generateCallCount, 3);
    });

    test('takes the retry count and the nudge text from the caller', () async {
      final registry = SkillRegistry()
        ..add(_textSkill('packing-list'), selected: true);
      final chat = _FakeAgentChat.turns([
        [_loadSkill('packing-list')],
        <ModelResponse>[],
        <ModelResponse>[],
        [const TextResponse('Pack a towel.')],
      ]);
      final loop = AgentLoop(
        registry: registry,
        executors: const [],
        emptyAfterSkillRetries: 2,
        emptyAfterSkillNudge: 'Go on.',
      );

      final events = await loop.run(chat, 'what should I pack?').toList();

      final retries = events.whereType<EmptyAnswerRetryEvent>().toList();
      expect(retries.map((e) => e.attempt), [1, 2]);
      expect(retries.map((e) => e.nudge), ['Go on.', 'Go on.']);
      expect(chat.userMessages.map((m) => m.text), [
        'what should I pack?',
        'Go on.',
        'Go on.',
      ]);
      expect((events.last as DoneEvent).text, 'Pack a towel.');
      expect(chat.generateCallCount, 4);
    });

    test('an empty answer after an intent result is not retried', () async {
      final registry = SkillRegistry()
        ..add(_intentSkill('get-current-time'), selected: true);
      final executor = _FakeExecutor(
        SkillType.intent,
        result: const TextResult('2026-10-15T09:00:00 Thursday'),
      );
      final chat = _FakeAgentChat.turns([
        [_loadSkill('get-current-time')],
        [
          _runIntent({
            'intent': 'get_current_date_and_time',
            'parameters': '{}',
          }),
        ],
        <ModelResponse>[],
      ]);
      final loop = AgentLoop(registry: registry, executors: [executor]);

      final events = await loop.run(chat, 'what time is it?').toList();

      expect(events.whereType<EmptyAnswerRetryEvent>(), isEmpty);
      final done = events.whereType<DoneEvent>().single;
      expect(done.runtimeType, DoneEvent);
      expect(done.text, '');
      expect(chat.generateCallCount, 3);
      expect(chat.userMessages, hasLength(1), reason: 'no nudge was sent');
    });

    test('a loadSkill that found nothing is not retried either', () async {
      final chat = _FakeAgentChat.turns([
        [_loadSkill('nope')],
        <ModelResponse>[],
      ]);
      final loop = AgentLoop(registry: SkillRegistry(), executors: const []);

      final events = await loop.run(chat, 'load nope').toList();

      expect(events.whereType<EmptyAnswerRetryEvent>(), isEmpty);
      expect(events.last.runtimeType, DoneEvent);
      expect(chat.generateCallCount, 2);
    });

    test(
      '0 retries: no nudge, the turn ends with an empty DoneEvent',
      () async {
        final registry = SkillRegistry()
          ..add(_textSkill('packing-list'), selected: true);
        final chat = _FakeAgentChat.turns([
          [_loadSkill('packing-list')],
          <ModelResponse>[],
          [const TextResponse('never reached')],
        ]);
        final loop = AgentLoop(
          registry: registry,
          executors: const [],
          emptyAfterSkillRetries: 0,
        );

        final events = await loop.run(chat, 'what should I pack?').toList();

        expect(events.whereType<EmptyAnswerRetryEvent>(), isEmpty);
        // Still a DoneEvent with empty text, as before; its subclass names the
        // skill.
        expect(events.last, isA<DoneEvent>());
        expect((events.last as DoneEvent).text, '');
        expect(events.last, isA<EmptyAnswerEvent>());
        expect(chat.generateCallCount, 2);
        expect(chat.received, hasLength(2));
      },
    );

    test('no retry when maxIterations has no generation left', () async {
      final registry = SkillRegistry()
        ..add(_textSkill('packing-list'), selected: true);
      final chat = _FakeAgentChat.turns([
        [_loadSkill('packing-list')],
        <ModelResponse>[],
        [const TextResponse('never reached')],
      ]);
      final loop = AgentLoop(
        registry: registry,
        executors: const [],
        maxIterations: 2,
      );

      final events = await loop.run(chat, 'what should I pack?').toList();

      expect(events.whereType<EmptyAnswerRetryEvent>(), isEmpty);
      expect(events.last, isA<EmptyAnswerEvent>());
      expect(chat.generateCallCount, 2);
      expect(chat.received, hasLength(2));
    });

    test('the retry runs within what is left of maxIterations', () async {
      final registry = SkillRegistry()
        ..add(_textSkill('packing-list'), selected: true);
      // Generation 3 (the retry) calls a tool again; a 4th would exceed the
      // cap of 3.
      final chat = _FakeAgentChat.turns([
        [_loadSkill('packing-list')],
        <ModelResponse>[],
        [_loadSkill('packing-list')],
        [const TextResponse('never reached')],
      ]);
      final loop = AgentLoop(
        registry: registry,
        executors: const [],
        maxIterations: 3,
      );

      final events = await loop.run(chat, 'what should I pack?').toList();

      expect(events.whereType<EmptyAnswerRetryEvent>(), hasLength(1));
      expect(events.last, isA<MaxIterationsEvent>());
      expect((events.last as MaxIterationsEvent).iterations, 3);
      expect(events.whereType<DoneEvent>(), isEmpty);
      expect(chat.generateCallCount, 3);
    });

    test('a cancel before the retry ends the turn with no nudge', () async {
      final registry = SkillRegistry()
        ..add(_textSkill('packing-list'), selected: true);
      final chat = _FakeAgentChat.turns([
        [_loadSkill('packing-list')],
        <ModelResponse>[],
        [const TextResponse('never reached')],
      ]);
      final loop = AgentLoop(registry: registry, executors: const []);

      // False through both generations' own checks, true once the empty one
      // has run: the first poll after it is the loop's check before a retry.
      final events = await loop
          .run(
            chat,
            'what should I pack?',
            isCancelled: () => chat.generateCallCount >= 2,
          )
          .toList();

      expect(events.whereType<EmptyAnswerRetryEvent>(), isEmpty);
      expect(events.whereType<DoneEvent>(), isEmpty);
      expect(events.whereType<MaxIterationsEvent>(), isEmpty);
      expect(chat.received, hasLength(2), reason: 'no nudge was sent');
      expect(chat.generateCallCount, 2);
    });

    test(
      'a cancel during the retry ends the turn with no EmptyAnswerEvent',
      () async {
        final registry = SkillRegistry()
          ..add(_textSkill('packing-list'), selected: true);
        final chat = _FakeAgentChat.turns([
          [_loadSkill('packing-list')],
          <ModelResponse>[],
          <ModelResponse>[], // the retry, stopped before its first token
        ]);
        final loop = AgentLoop(registry: registry, executors: const []);

        // True once the retried generation has run: core polls nothing after
        // a call-free generation, so the loop's own check is the only one.
        final events = await loop
            .run(
              chat,
              'what should I pack?',
              isCancelled: () => chat.generateCallCount >= 3,
            )
            .toList();

        expect(events.map((e) => e.runtimeType), [
          SkillLoadEvent,
          EmptyAnswerRetryEvent,
        ]);
        expect(events.whereType<DoneEvent>(), isEmpty);
        expect(chat.generateCallCount, 3);
      },
    );

    test(
      '0 retries: a cancel during the empty answer ends with no DoneEvent',
      () async {
        final registry = SkillRegistry()
          ..add(_textSkill('packing-list'), selected: true);
        final chat = _FakeAgentChat.turns([
          [_loadSkill('packing-list')],
          <ModelResponse>[],
        ]);
        final loop = AgentLoop(
          registry: registry,
          executors: const [],
          emptyAfterSkillRetries: 0,
        );

        final events = await loop
            .run(
              chat,
              'what should I pack?',
              isCancelled: () => chat.generateCallCount >= 2,
            )
            .toList();

        expect(events.map((e) => e.runtimeType), [SkillLoadEvent]);
        expect(events.whereType<DoneEvent>(), isEmpty);
        expect(chat.generateCallCount, 2);
      },
    );

    test('a negative retry count is refused', () {
      expect(
        () => AgentLoop(
          registry: SkillRegistry(),
          executors: const [],
          emptyAfterSkillRetries: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => AgentSession(
          chat: _FakeAgentChat(const []),
          registry: SkillRegistry(),
          executors: const [],
          emptyAfterSkillRetries: -1,
        ),
        throwsArgumentError,
      );
    });

    test('AgentSession passes the retry settings to its loop', () async {
      final registry = SkillRegistry()
        ..add(_textSkill('packing-list'), selected: true);
      final chat = _FakeAgentChat.turns([
        [_loadSkill('packing-list')],
        <ModelResponse>[],
        <ModelResponse>[],
        [const TextResponse('Pack a towel.')],
      ]);
      final session = AgentSession(
        chat: chat,
        registry: registry,
        executors: const [],
        emptyAfterSkillRetries: 2,
        emptyAfterSkillNudge: 'Go on.',
      );

      final events = await session.ask('what should I pack?').toList();

      expect(events.whereType<EmptyAnswerRetryEvent>().map((e) => e.nudge), [
        'Go on.',
        'Go on.',
      ]);
      expect((events.last as DoneEvent).text, 'Pack a towel.');
    });
  });

  group('AgentLoop — runIntent with a skillName', () {
    test('runs the intent the call names, not the skill', () async {
      // Small models add the loaded skill's name to the intent call.
      final registry = SkillRegistry()
        ..add(_intentSkill('get-current-time'), selected: true);
      final chat = _FakeAgentChat([
        _runIntent({
          'skillName': 'get-current-time',
          'intent': 'get_current_date_and_time',
          'parameters': '{}',
        }),
        const TextResponse('It is morning.'),
      ]);
      final loop = AgentLoop(
        registry: registry,
        executors: [NativeIntentExecutor()],
      );

      final events = await loop.run(chat, 'what time is it?').toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result, isA<TextResult>());
      expect(
        (result as TextResult).text,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}T')),
      );
      expect(events.whereType<AgentErrorEvent>(), isEmpty);
    });

    test('keeps the registered skill for the event and the secret', () async {
      final registry = SkillRegistry()
        ..add(
          _intentSkill('get-current-time', requireSecret: true),
          selected: true,
        );
      final executor = _FakeExecutor(SkillType.intent);
      final secrets = SecretStore()..set('get-current-time', 'sk-1');
      final chat = _FakeAgentChat([
        _runIntent({
          'skillName': 'get-current-time',
          'intent': 'get_current_date_and_time',
          'parameters': '{}',
        }),
        const TextResponse('ok'),
      ]);
      final loop = AgentLoop(
        registry: registry,
        executors: [executor],
        secretStore: secrets,
      );

      final events = await loop.run(chat, 'what time is it?').toList();

      expect(executor.calls.single.skill.name, 'get_current_date_and_time');
      expect(executor.calls.single.skill.type, SkillType.intent);
      expect(executor.calls.single.secret, 'sk-1');
      expect(
        events.whereType<ToolCallEvent>().single.skill?.name,
        'get-current-time',
      );
    });

    test('without an intent the registered skill runs, as before', () async {
      final registry = SkillRegistry()
        ..add(_intentSkill('get-current-time'), selected: true);
      final executor = _FakeExecutor(SkillType.intent);
      final chat = _FakeAgentChat([
        _runIntent({'skillName': 'get-current-time', 'parameters': '{}'}),
        const TextResponse('ok'),
      ]);
      final loop = AgentLoop(registry: registry, executors: [executor]);

      await loop.run(chat, 'what time is it?').toList();

      expect(executor.calls.single.skill.name, 'get-current-time');
    });
  });

  group('AgentLoop — runMcp with a skillName', () {
    Skill mcpSkill({bool requireSecret = false}) => Skill(
      name: 'weather',
      description: 'Look up the weather forecast.',
      instructions: 'Call the `runMcp` tool with toolName: get_forecast.',
      type: SkillType.mcp,
      metadata: SkillMetadata(requireSecret: requireSecret),
    );

    test('runs the tool the call names, not the skill', () async {
      final registry = SkillRegistry()..add(mcpSkill(), selected: true);
      final chat = _FakeAgentChat([
        const FunctionCallResponse(
          name: 'runMcp',
          args: {
            'skillName': 'weather',
            'toolName': 'get_forecast',
            'input': '{"city":"Paris"}',
          },
        ),
        const TextResponse('Sunny.'),
      ]);
      final loop = AgentLoop(
        registry: registry,
        executors: [_echoMcpExecutor('get_forecast')],
      );

      final events = await loop.run(chat, 'weather in Paris?').toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect((result as TextResult).text, 'get_forecast:{"city":"Paris"}');
      expect(events.whereType<AgentErrorEvent>(), isEmpty);
    });

    test('keeps the registered skill for the event and the secret', () async {
      final registry = SkillRegistry()
        ..add(mcpSkill(requireSecret: true), selected: true);
      final executor = _FakeExecutor(SkillType.mcp);
      final secrets = SecretStore()..set('weather', 'sk-1');
      final chat = _FakeAgentChat([
        const FunctionCallResponse(
          name: 'runMcp',
          args: {
            'skillName': 'weather',
            'toolName': 'get_forecast',
            'input': '{}',
          },
        ),
        const TextResponse('ok'),
      ]);
      final loop = AgentLoop(
        registry: registry,
        executors: [executor],
        secretStore: secrets,
      );

      final events = await loop.run(chat, 'weather?').toList();

      expect(executor.calls.single.skill.name, 'get_forecast');
      expect(executor.calls.single.skill.type, SkillType.mcp);
      expect(executor.calls.single.secret, 'sk-1');
      expect(events.whereType<ToolCallEvent>().single.skill?.name, 'weather');
    });

    test('without a toolName the registered skill runs, as before', () async {
      final registry = SkillRegistry()..add(mcpSkill(), selected: true);
      final executor = _FakeExecutor(SkillType.mcp);
      final chat = _FakeAgentChat([
        const FunctionCallResponse(
          name: 'runMcp',
          args: {'skillName': 'weather', 'input': '{}'},
        ),
        const TextResponse('ok'),
      ]);
      final loop = AgentLoop(registry: registry, executors: [executor]);

      await loop.run(chat, 'weather?').toList();

      expect(executor.calls.single.skill.name, 'weather');
    });
  });

  group('AgentLoop — runIntent after a text-only skill', () {
    // Gemma 4 E2B calls runIntent with an invented intent after loading an
    // instruction-only skill. The result must tell it the skill calls no tool.
    Future<(List<AgentEvent>, _FakeAgentChat)> runAfterLoading(
      Skill loaded,
      Map<String, dynamic> intentArgs, {
      List<SkillExecutor>? executors,
    }) async {
      final registry = SkillRegistry()..add(loaded, selected: true);
      final chat = _FakeAgentChat([
        _loadSkill(loaded.name),
        _runIntent(intentArgs),
        const TextResponse('Pack a towel.'),
      ]);
      final loop = AgentLoop(
        registry: registry,
        executors: executors ?? [TextSkillExecutor(), NativeIntentExecutor()],
      );
      final events = await loop.run(chat, 'what should I pack?').toList();
      return (events, chat);
    }

    test(
      'an unknown intent is answered with "the skill calls no tool"',
      () async {
        final (events, chat) = await runAfterLoading(
          _textSkill('packing-list'),
          {'intent': 'packing-list.suggest', 'parameters': '{}'},
        );

        final fed = chat.toolResponses.last;
        expect(fed.toolName, 'runIntent');
        expect(fed.text, contains(r'skill \"packing-list\" calls no tool'));
        expect(fed.text, contains('Answer the user directly'));
        expect(fed.text, isNot(contains('Unknown intent')));
        expect(
          events.whereType<AgentErrorEvent>().single.message,
          contains('calls no tool'),
        );
        expect((events.last as DoneEvent).text, 'Pack a towel.');
      },
    );

    test('also when no executor can run intents at all', () async {
      final (_, chat) = await runAfterLoading(
        _textSkill('packing-list'),
        {'intent': 'packing-list', 'parameters': '{}'},
        executors: [TextSkillExecutor()],
      );

      expect(chat.toolResponses.last.text, contains('calls no tool'));
      expect(
        chat.toolResponses.last.text,
        isNot(contains('No executor available')),
      );
    });

    test(
      'after a skill that is not text-only it stays "Unknown intent"',
      () async {
        final (_, chat) = await runAfterLoading(
          _intentSkill('get-current-time'),
          {'intent': 'packing-list.suggest', 'parameters': '{}'},
        );

        expect(chat.toolResponses.last.text, contains('Unknown intent'));
        expect(chat.toolResponses.last.text, isNot(contains('calls no tool')));
      },
    );

    test('an intent the app runs still runs', () async {
      final (events, _) = await runAfterLoading(_textSkill('packing-list'), {
        'intent': 'get_current_date_and_time',
        'parameters': '{}',
      });

      expect(
        events.whereType<ToolResultEvent>().single.result,
        isA<TextResult>(),
      );
    });

    test('a known intent keeps its own error', () async {
      final (_, chat) = await runAfterLoading(_textSkill('packing-list'), {
        'intent': 'send_email',
        'parameters': '{"extra_email": "not-an-address"}',
      });

      expect(chat.toolResponses.last.text, contains('invalid email'));
      expect(chat.toolResponses.last.text, isNot(contains('calls no tool')));
    });

    test('a known intent inside the parameters keeps its own error', () async {
      final (_, chat) = await runAfterLoading(_textSkill('packing-list'), {
        'intent': 'packing-list',
        'parameters':
            '{"intent": "send_email", '
            '"parameters": {"extra_email": "not-an-address"}}',
      });

      expect(chat.toolResponses.last.text, contains('Invalid parameters'));
      expect(chat.toolResponses.last.text, isNot(contains('calls no tool')));
    });
  });

  group('AgentLoop — object arguments', () {
    test(
      'a Map or List where the tool asks for a JSON string is JSON',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final intents = _FakeExecutor(SkillType.intent, name: 'intents');
        final js = _FakeExecutor(SkillType.js, name: 'js');
        final chat = _FakeAgentChat([
          _runIntent({
            'intent': 'start_timer',
            'parameters': {'seconds': 10, 'label': 'tea'},
          }),
          const FunctionCallResponse(
            name: 'runSkill',
            args: {
              'skillName': 'calculate-hash',
              'data': ['a', 1],
            },
          ),
          const TextResponse('ok'),
        ]);
        final loop = AgentLoop(registry: registry, executors: [intents, js]);

        await loop.run(chat, 'go').toList();

        expect(intents.calls.single.dataJson, '{"seconds":10,"label":"tea"}');
        expect(js.calls.single.dataJson, '["a",1]');
      },
    );
  });

  group('AgentSession facade', () {
    test('ask() drives the loop via the wrapped chat', () async {
      final registry = SkillRegistry()..add(_jsSkill(), selected: true);
      final executor = _FakeExecutor(
        SkillType.js,
        result: const TextResult('42'),
      );
      final chat = _FakeAgentChat([
        _runSkill('calculate-hash'),
        const TextResponse('the answer is 42'),
      ]);

      final session = AgentSession(
        chat: chat,
        registry: registry,
        executors: [executor],
      );
      final events = await session.ask('compute').toList();

      expect(events.last, isA<DoneEvent>());
      expect((events.last as DoneEvent).text, contains('42'));
      expect(executor.calls, hasLength(1));
    });

    test('session.secretStore is the same store the loop reads', () async {
      // The facade must share one SecretStore with its loop; mutating the
      // exposed store must reach execution time.
      final secretSkill = Skill(
        name: 'weather',
        description: 'Get weather.',
        instructions: 'Call the `run_js` tool.',
        type: SkillType.js,
        metadata: const SkillMetadata(requireSecret: true),
      );
      final registry = SkillRegistry()..add(secretSkill, selected: true);
      final executor = _FakeExecutor(SkillType.js);
      final chat = _FakeAgentChat([
        _runSkill('weather'),
        const TextResponse('sunny'),
      ]);

      final session = AgentSession(
        chat: chat,
        registry: registry,
        executors: [executor],
      );
      // Set the secret AFTER construction via the facade's exposed store.
      session.secretStore.set('weather', 'sk-shared-9');

      await session.ask('weather?').toList();

      expect(executor.calls.single.secret, 'sk-shared-9');
    });
  });

  group('AgentLoop — streaming (VoiceSession parity)', () {
    test(
      'a multi-token final answer streams as ordered TextChunkEvents',
      () async {
        // One turn, three tokens — the real generateChatResponseAsync yields the
        // model's answer token-by-token; the loop must surface each immediately.
        final chat = _FakeAgentChat.turns([
          [
            const TextResponse('Hel'),
            const TextResponse('lo '),
            const TextResponse('world'),
          ],
        ]);
        final loop = AgentLoop(registry: SkillRegistry(), executors: const []);

        final events = await loop.run(chat, 'hi').toList();

        final chunks = events
            .whereType<TextChunkEvent>()
            .map((e) => e.text)
            .toList();
        expect(chunks, ['Hel', 'lo ', 'world'], reason: 'streamed in order');
        // DoneEvent carries the full accumulated answer.
        expect(events.last, isA<DoneEvent>());
        expect((events.last as DoneEvent).text, 'Hello world');
        expect(chunks.join(), (events.last as DoneEvent).text);
        expect(chat.generateCallCount, 1);
      },
    );

    test('empty tokens are not surfaced as TextChunkEvents', () async {
      final chat = _FakeAgentChat.turns([
        [
          const TextResponse(''),
          const TextResponse('hi'),
          const TextResponse(''),
        ],
      ]);
      final loop = AgentLoop(registry: SkillRegistry(), executors: const []);

      final events = await loop.run(chat, 'x').toList();

      expect(events.whereType<TextChunkEvent>().map((e) => e.text).toList(), [
        'hi',
      ], reason: 'empty tokens dropped, no blank TextChunkEvent');
      expect((events.last as DoneEvent).text, 'hi');
    });

    test('streams preamble text BEFORE a tool call, then dispatches, then the '
        'final answer — DoneEvent carries only the final turn text', () async {
      final registry = SkillRegistry()..add(_jsSkill(), selected: true);
      final executor = _FakeExecutor(
        SkillType.js,
        result: const TextResult('5'),
      );
      // Turn 1: the model narrates, THEN calls the tool (both in one stream).
      // Turn 2: the final answer.
      final chat = _FakeAgentChat.turns([
        [
          const TextResponse('Let me check. '),
          _runSkill('calculate-hash', data: '{"n":1}'),
        ],
        [const TextResponse('Result is 5.')],
      ]);
      final loop = AgentLoop(registry: registry, executors: [executor]);

      final events = await loop.run(chat, 'compute').toList();

      // Ordering: preamble text streams before the tool call is dispatched.
      final preambleIdx = events.indexWhere(
        (e) => e is TextChunkEvent && e.text == 'Let me check. ',
      );
      final toolCallIdx = events.indexWhere((e) => e is ToolCallEvent);
      expect(preambleIdx, isNonNegative);
      expect(toolCallIdx, greaterThan(preambleIdx));

      // The executor ran with the model's data.
      expect(executor.calls.single.dataJson, '{"n":1}');
      // Both text spans streamed, preamble first then final answer.
      expect(
        events.whereType<TextChunkEvent>().map((e) => e.text),
        containsAllInOrder(['Let me check. ', 'Result is 5.']),
      );
      // DoneEvent = the FINAL turn's text only, not the preamble.
      expect((events.last as DoneEvent).text, 'Result is 5.');
      expect(chat.generateCallCount, 2);
    });

    test(
      'ThinkingResponse content folds into the answer text (defensive)',
      () async {
        // The agent creates its chat with thinking off, so this never fires in
        // production — but if a thinking token ever reaches the loop it must not
        // be dropped silently; it folds into the streamed answer (parity with the
        // pre-streaming switch's `ThinkingResponse(:content) => content`).
        final chat = _FakeAgentChat.turns([
          [const ThinkingResponse('hmm '), const TextResponse('answer')],
        ]);
        final loop = AgentLoop(registry: SkillRegistry(), executors: const []);

        final events = await loop.run(chat, 'q').toList();

        expect(events.whereType<TextChunkEvent>().map((e) => e.text).toList(), [
          'hmm ',
          'answer',
        ]);
        expect((events.last as DoneEvent).text, 'hmm answer');
      },
    );

    test('cancel after the stream ends (before dispatch) answers the pending '
        'call cancelled and never runs it', () async {
      final registry = SkillRegistry()..add(_jsSkill(), selected: true);
      final executor = _FakeExecutor(SkillType.js);
      // A single pure tool-call turn. isCancelled is false for the pre-gen
      // check (generateCallCount == 0) and flips true once the generation has
      // run (== 1) — i.e. exactly at the post-stream cancel checkpoint.
      final chat = _FakeAgentChat.turns([
        [_runSkill('calculate-hash')],
      ]);
      final loop = AgentLoop(registry: registry, executors: [executor]);

      final events = await loop
          .run(chat, 'go', isCancelled: () => chat.generateCallCount >= 1)
          .toList();

      // The tool must NOT have executed...
      expect(executor.calls, isEmpty);
      // ...but the committed call is balanced with a cancelled tool-response
      // so it never dangles into the next turn.
      expect(chat.toolResponses.single.text, contains('cancelled'));
      // No result + no terminal Done/MaxIterations after a barge-in.
      expect(events.whereType<ToolResultEvent>(), isEmpty);
      expect(events.whereType<DoneEvent>(), isEmpty);
      expect(events.whereType<MaxIterationsEvent>(), isEmpty);
    });

    test(
      'streaming works end-to-end through the AgentSession facade',
      () async {
        final chat = _FakeAgentChat.turns([
          [const TextResponse('4'), const TextResponse('2')],
        ]);
        final session = AgentSession(
          chat: chat,
          registry: SkillRegistry(),
          executors: const [],
        );

        final events = await session.ask('answer?').toList();

        expect(events.whereType<TextChunkEvent>().map((e) => e.text).toList(), [
          '4',
          '2',
        ]);
        expect((events.last as DoneEvent).text, '42');
      },
    );
  });

  group('AgentLoop — streaming: error path & parallel/edge coverage', () {
    test('a mid-stream error after a committed tool call balances the pending '
        'call before rethrowing (no dangling call)', () async {
      final registry = SkillRegistry()..add(_jsSkill(), selected: true);
      final executor = _FakeExecutor(SkillType.js);
      // Turn 0 yields a complete tool call (core commits it to the persistent
      // history the moment it yields), then the native decode stream errors on
      // a later token. The rethrow must NOT skip balancing the committed call.
      final chat = _FakeAgentChat.turns(
        [
          [_runSkill('calculate-hash')],
        ],
        errorAfterTurns: {0},
      );
      final loop = AgentLoop(registry: registry, executors: [executor]);

      // The error MUST surface — never hidden (no-masking-failure rule)...
      await expectLater(
        loop.run(chat, 'go').toList(),
        throwsA(isA<StateError>()),
      );
      // ...and the committed-but-unexecuted call must be balanced so it does
      // not dangle into the next ask() on the reused chat.
      expect(chat.toolResponses, hasLength(1));
      expect(chat.toolResponses.single.text, contains('failed'));
      // It was never dispatched (the error landed before dispatch).
      expect(executor.calls, isEmpty);
    });

    test(
      'barge-in BETWEEN parallel dispatched calls answers the remaining call '
      'cancelled and never runs it',
      () async {
        final registry = SkillRegistry()
          ..add(_jsSkill(name: 'a'), selected: true)
          ..add(_jsSkill(name: 'b'), selected: true);
        final executor = _FakeExecutor(
          SkillType.js,
          result: const TextResult('ok'),
        );
        // One stream: preamble text THEN two parallel calls.
        final chat = _FakeAgentChat.turns([
          [
            const TextResponse('working '),
            ParallelFunctionCallResponse(
              calls: [
                _runSkill('a', data: '{"i":1}'),
                _runSkill('b', data: '{"i":2}'),
              ],
            ),
          ],
        ]);
        final loop = AgentLoop(registry: registry, executors: [executor]);

        // Cancel the moment the FIRST tool result is observed, so dispatch of
        // the second parallel call sees cancelled() true (pending.sublist(i)).
        var cancel = false;
        final events = <AgentEvent>[];
        await for (final e in loop.run(chat, 'go', isCancelled: () => cancel)) {
          events.add(e);
          if (e is ToolResultEvent) cancel = true;
        }

        // Only 'a' ran; 'b' was answered cancelled, never executed.
        expect(executor.calls, hasLength(1));
        expect(executor.calls.single.dataJson, '{"i":1}');
        // Preamble streamed before the first tool call.
        final preambleIdx = events.indexWhere((e) => e is TextChunkEvent);
        final firstCallIdx = events.indexWhere((e) => e is ToolCallEvent);
        expect(preambleIdx, isNonNegative);
        expect(firstCallIdx, greaterThan(preambleIdx));
        // Two tool-responses fed back: 'a' real + 'b' cancelled.
        expect(chat.toolResponses, hasLength(2));
        expect(
          chat.toolResponses.where((m) => m.text.contains('cancelled')),
          hasLength(1),
        );
        // No terminal event after a barge-in.
        expect(events.whereType<DoneEvent>(), isEmpty);
        expect(events.whereType<MaxIterationsEvent>(), isEmpty);
      },
    );

    test(
      'streams preamble text before PARALLEL calls, dispatches both, then the '
      'final answer',
      () async {
        final registry = SkillRegistry()
          ..add(_jsSkill(name: 'a'), selected: true)
          ..add(_jsSkill(name: 'b'), selected: true);
        final executor = _FakeExecutor(
          SkillType.js,
          result: const TextResult('ok'),
        );
        final chat = _FakeAgentChat.turns([
          [
            const TextResponse('Let me check both. '),
            ParallelFunctionCallResponse(
              calls: [
                _runSkill('a', data: '{"i":1}'),
                _runSkill('b', data: '{"i":2}'),
              ],
            ),
          ],
          [const TextResponse('Both done.')],
        ]);
        final loop = AgentLoop(registry: registry, executors: [executor]);

        final events = await loop.run(chat, 'do both').toList();

        // Preamble streamed before every tool call.
        final preambleIdx = events.indexWhere(
          (e) => e is TextChunkEvent && e.text == 'Let me check both. ',
        );
        final callIdxs = events.indexed
            .where((r) => r.$2 is ToolCallEvent)
            .map((r) => r.$1);
        expect(preambleIdx, isNonNegative);
        expect(callIdxs.every((i) => i > preambleIdx), isTrue);
        // Both parallel calls executed with their own data.
        expect(executor.calls, hasLength(2));
        expect(executor.calls[0].dataJson, '{"i":1}');
        expect(executor.calls[1].dataJson, '{"i":2}');
        // DoneEvent = final turn only; preamble did NOT leak in.
        expect((events.last as DoneEvent).text, 'Both done.');
        expect(chat.generateCallCount, 2);
      },
    );

    test(
      'an empty stream (model produced nothing) ends with DoneEvent("")',
      () async {
        // One turn that yields zero responses — neither text nor a call.
        final chat = _FakeAgentChat.turns([<ModelResponse>[]]);
        final loop = AgentLoop(registry: SkillRegistry(), executors: const []);

        final events = await loop.run(chat, 'x').toList();

        expect(events.whereType<TextChunkEvent>(), isEmpty);
        expect(events.single, isA<DoneEvent>());
        expect((events.single as DoneEvent).text, '');
        // Terminates on the empty turn, does not spin to maxIterations.
        expect(chat.generateCallCount, 1);
      },
    );
  });

  group('AgentLoop — subscription lifecycle', () {
    test('run() is lazy — nothing runs until the stream is listened', () async {
      final chat = _FakeAgentChat([const TextResponse('hi')]);
      final loop = AgentLoop(registry: SkillRegistry(), executors: const []);

      final stream = loop.run(chat, 'hello');
      // Not listened yet: the user message must NOT have been staged, and no
      // generation started.
      await Future<void>.delayed(Duration.zero);
      expect(
        chat.received,
        isEmpty,
        reason: 'no work before the stream is listened',
      );
      expect(chat.generateCallCount, 0);

      // Consuming it now runs the turn.
      final events = await stream.toList();
      expect(chat.received.first.text, 'hello');
      expect(events.last, isA<DoneEvent>());
    });

    test(
      'cancelling the subscription stops the runaway loop (no orphaned turns)',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final executor = _FakeExecutor(SkillType.js);
        // The model would call the tool forever if never stopped.
        final chat = _FakeAgentChat(
          List.generate(50, (_) => _runSkill('calculate-hash')),
        );
        final loop = AgentLoop(
          registry: registry,
          executors: [executor],
          maxIterations: 50,
        );

        late final StreamSubscription<AgentEvent> sub;
        final firstEvent = Completer<void>();
        sub = loop.run(chat, 'go').listen((_) {
          if (!firstEvent.isCompleted) firstEvent.complete();
        });
        await firstEvent.future;
        await sub.cancel();
        // Give a detached driver ample time to keep running, if it were going to.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Subscription-cancel is folded into the signal core polls between
        // turns, so the loop stops far short of the 50-turn cap instead of
        // running every remaining generation + tool side-effect to a dead
        // controller.
        expect(
          chat.generateCallCount,
          lessThan(50),
          reason: 'subscription-cancel must stop the loop',
        );
      },
    );
  });

  group('AgentLoop — maxIterations boundary', () {
    test(
      'settling with a call-free answer on the LAST allowed turn → DoneEvent, '
      'not MaxIterationsEvent',
      () async {
        final registry = SkillRegistry()..add(_jsSkill(), selected: true);
        final executor = _FakeExecutor(SkillType.js);
        // Two tool turns, then a final answer on the third (last) allowed turn.
        final chat = _FakeAgentChat([
          _runSkill('calculate-hash'),
          _runSkill('calculate-hash'),
          const TextResponse('final answer'),
        ]);
        final loop = AgentLoop(
          registry: registry,
          executors: [executor],
          maxIterations: 3,
        );

        final events = await loop.run(chat, 'go').toList();

        // The model got its final generation within budget — the off-by-one in
        // `turn < maxToolTurns` must allow exactly the 3rd generation.
        expect(events.last, isA<DoneEvent>());
        expect((events.last as DoneEvent).text, 'final answer');
        expect(events.whereType<MaxIterationsEvent>(), isEmpty);
        expect(chat.generateCallCount, 3);
      },
    );
  });

  group('AgentLoop — image input', () {
    test('sends an image message when imageBytes is given', () async {
      final chat = _FakeAgentChat([
        const TextResponse('a printed card'),
      ], supportImage: true);
      final loop = AgentLoop(
        registry: SkillRegistry(),
        executors: [_FakeExecutor(SkillType.textOnly)],
      );
      final bytes = Uint8List.fromList([1, 2, 3]);

      await loop.run(chat, 'what is this?', imageBytes: bytes).toList();

      final message = chat.received.single;
      expect(message.hasImage, isTrue);
      expect(message.imageBytes, bytes);
      expect(message.text, 'what is this?');
      expect(message.isUser, isTrue);
    });

    test('sends a text-only message when imageBytes is omitted', () async {
      final chat = _FakeAgentChat([const TextResponse('hi')]);
      final loop = AgentLoop(
        registry: SkillRegistry(),
        executors: [_FakeExecutor(SkillType.textOnly)],
      );

      await loop.run(chat, 'hello').toList();

      expect(chat.received.single.hasImage, isFalse);
      expect(chat.received.single.text, 'hello');
    });

    test('fails when the chat was built without image support', () async {
      // The engines disagree on this case — FFI/mobile drop the image and
      // answer text-only, web MediaPipe throws. Fail here so the behaviour is
      // identical everywhere. The guard runs in the driver, so it surfaces as a
      // stream error (not a synchronous throw).
      final chat = _FakeAgentChat([const TextResponse('never reached')]);
      final loop = AgentLoop(
        registry: SkillRegistry(),
        executors: [_FakeExecutor(SkillType.textOnly)],
      );

      await expectLater(
        loop
            .run(chat, 'what is this?', imageBytes: Uint8List.fromList([1]))
            .toList(),
        throwsArgumentError,
      );
      expect(chat.received, isEmpty);
    });

    test('fails on empty imageBytes', () async {
      final chat = _FakeAgentChat([
        const TextResponse('never reached'),
      ], supportImage: true);
      final loop = AgentLoop(
        registry: SkillRegistry(),
        executors: [_FakeExecutor(SkillType.textOnly)],
      );

      await expectLater(
        loop.run(chat, 'what is this?', imageBytes: Uint8List(0)).toList(),
        throwsArgumentError,
      );
      expect(chat.received, isEmpty);
    });

    test('AgentSession.ask forwards imageBytes to the loop', () async {
      final chat = _FakeAgentChat([
        const TextResponse('ok'),
      ], supportImage: true);
      final session = AgentSession(
        chat: chat,
        registry: SkillRegistry(),
        executors: [_FakeExecutor(SkillType.textOnly)],
      );
      final bytes = Uint8List.fromList([9, 9]);

      await session.ask('what is this?', imageBytes: bytes).toList();

      expect(chat.received.single.hasImage, isTrue);
      expect(chat.received.single.imageBytes, bytes);
    });
  });

  group('AgentLoop — audio input', () {
    AgentLoop loop() => AgentLoop(
      registry: SkillRegistry(),
      executors: [_FakeExecutor(SkillType.textOnly)],
    );

    test('sends the recording on the turn\'s user message', () async {
      final chat = _FakeAgentChat([
        const TextResponse('Paris'),
      ], supportAudio: true);
      final audio = Uint8List.fromList([82, 73, 70, 70]);

      await loop().run(chat, 'answer briefly', audioBytes: audio).toList();

      final message = chat.received.single;
      expect(message.hasAudio, isTrue);
      expect(message.audioBytes, audio);
      expect(message.text, 'answer briefly');
      expect(message.isUser, isTrue);
      expect(message.hasImage, isFalse);
    });

    test('carries an image and a recording on the same message', () async {
      final chat = _FakeAgentChat(
        [const TextResponse('a cat')],
        supportImage: true,
        supportAudio: true,
      );
      final image = Uint8List.fromList([1, 2]);
      final audio = Uint8List.fromList([3, 4]);

      await loop().run(chat, '', imageBytes: image, audioBytes: audio).toList();

      final message = chat.received.single;
      expect(message.imageBytes, image);
      expect(message.images, [image]);
      expect(message.audioBytes, audio);
    });

    test(
      'takes an empty text when the recording carries the question',
      () async {
        final chat = _FakeAgentChat([
          const TextResponse('Paris'),
        ], supportAudio: true);

        final audio = Uint8List.fromList([1]);
        final events = await loop().run(chat, '', audioBytes: audio).toList();

        expect(chat.received.single.text, '');
        expect(chat.received.single.audioBytes, audio);
        expect((events.last as DoneEvent).text, 'Paris');
      },
    );

    test(
      'fails, and writes nothing to history, without supportAudio',
      () async {
        // The FFI session drops audio it was not set up for, and the model
        // answers as if nothing was said. The guard makes that an error.
        final chat = _FakeAgentChat([const TextResponse('never reached')]);

        await expectLater(
          loop()
              .run(chat, 'what did I say?', audioBytes: Uint8List.fromList([1]))
              .toList(),
          throwsArgumentError,
        );
        expect(chat.received, isEmpty);
        expect(chat.generateCallCount, 0);
      },
    );

    test('fails on empty audioBytes', () async {
      final chat = _FakeAgentChat([
        const TextResponse('never reached'),
      ], supportAudio: true);

      await expectLater(
        loop().run(chat, '', audioBytes: Uint8List(0)).toList(),
        throwsArgumentError,
      );
      expect(chat.received, isEmpty);
    });

    test('tool-result follow-ups in the turn carry no audio', () async {
      final chat = _FakeAgentChat.turns([
        [_loadSkill('missing-skill')],
        [const TextResponse('done')],
      ], supportAudio: true);
      final audio = Uint8List.fromList([5, 6, 7]);

      await loop().run(chat, '', audioBytes: audio).toList();

      expect(chat.received.first.audioBytes, audio);
      expect(chat.toolResponses, isNotEmpty);
      for (final response in chat.toolResponses) {
        expect(response.hasAudio, isFalse);
      }
    });

    test('AgentSession.ask forwards audioBytes to the loop', () async {
      final chat = _FakeAgentChat([
        const TextResponse('ok'),
      ], supportAudio: true);
      final session = AgentSession(
        chat: chat,
        registry: SkillRegistry(),
        executors: [_FakeExecutor(SkillType.textOnly)],
      );
      final audio = Uint8List.fromList([8, 8]);

      await session.ask('', audioBytes: audio).toList();

      expect(chat.received.single.audioBytes, audio);
    });
  });
}
