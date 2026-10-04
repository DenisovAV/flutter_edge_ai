import 'dart:async';
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

/// A scriptable fake [InferenceChat]: yields the next queued turn's token/call
/// stream per [generateChatResponseAsync] call and records every
/// [addQueryChunk] message (so a test can assert what was fed back to the
/// model). Subclasses the real [InferenceChat] (mirrors the genkit
/// `FakeInferenceChat` pattern) so no real session is created.
class _FakeAgentChat extends InferenceChat {
  /// Flat form: one [ModelResponse] per turn (each becomes a single-element
  /// token stream). Keeps every pre-streaming test constructing the fake the
  /// same way — `[a, b, c]` is still three separate turns.
  _FakeAgentChat(List<ModelResponse> responses, {super.supportImage})
    : _turns = [
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
  _FakeAgentChat.turns(this._turns, {this._errorAfterTurns = const {}})
    : super(sessionCreator: null, maxTokens: 1024);

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

      expect(
        events.whereType<TextChunkEvent>().map((e) => e.text).toList(),
        ['hi'],
        reason: 'empty tokens dropped, no blank TextChunkEvent',
      );
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
}
