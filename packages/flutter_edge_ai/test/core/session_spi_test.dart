import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/noop_session.dart';

/// A session whose turns the test scripts: each turn streams [tokens] and
/// reports [end] through `startTurn`.
final class _TurnSession extends InferenceModelSession {
  _TurnSession({this.tokens = const ['Hi'], this.end});

  List<String> tokens;
  TurnEnd? end;
  Object? sizeError;
  final staged = <Message>[];
  int turns = 0;
  bool closed = false;

  @override
  EngineTurn startTurn() {
    turns++;
    final end = this.end;
    return EngineTurn(
      text: Stream.fromIterable(tokens),
      end: end == null ? null : Future.value(end),
    );
  }

  /// Not through [startTurn], so a chat that skips it is seen: no turn is
  /// counted and no end is reported.
  @override
  Stream<String> getResponseAsync() => Stream.fromIterable(tokens);

  @override
  Future<String> getResponse() => getResponseAsync().join();

  @override
  Future<int> sizeInTokens(String text) async {
    if (sizeError case final error?) throw error;
    return text.length;
  }

  @override
  Future<void> addQueryChunk(Message message) async => staged.add(message);

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async => closed = true;
}

/// A model that extends [InferenceModel], so it gets core's openSession,
/// openChat and sessions, and records what reaches its engine SPI.
final class _Model extends InferenceModel {
  _Model({this.resolver, this.hooks});

  final ResolvedChatRequest Function(ChatRequest request)? resolver;
  final ChatTurnHooks? hooks;
  final requests = <SessionRequest>[];
  final opened = <_TurnSession>[];
  _TurnSession Function()? nextSession;

  @override
  InferenceModelSession? get session => null;

  @override
  int get maxTokens => 1024;

  @override
  ModelFileType get fileType => ModelFileType.task;

  @override
  PreferredBackend? get activeBackend => null;

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<Tool> tools = const [],
    int? maxOutputTokens,
  }) => throw UnimplementedError();

  @override
  Future<InferenceModelSession> openEngineSession(
    SessionRequest request,
  ) async {
    requests.add(request);
    final session = nextSession?.call() ?? _TurnSession();
    opened.add(session);
    return session;
  }

  @override
  List<InferenceModelSession> get engineSessions => [
    for (final s in opened)
      if (!s.closed) s,
  ];

  @override
  ResolvedChatRequest resolveChatRequest(ChatRequest request) =>
      resolver?.call(request) ?? super.resolveChatRequest(request);

  @override
  ChatTurnHooks createChatTurnHooks(ResolvedChatRequest request) =>
      hooks ?? super.createChatTurnHooks(request);

  @override
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async {}
}

/// Every value of [request], with this model's own type and image support.
ResolvedChatRequest _ownDefaults(ChatRequest request) => ResolvedChatRequest(
  modelType: request.modelType ?? ModelType.qwen3,
  supportImage: request.supportImage ?? true,
  supportAudio: request.supportAudio ?? false,
  supportsFunctionCalls: request.supportsFunctionCalls ?? false,
  tools: request.tools,
  maxFunctionBufferLength: request.maxFunctionBufferLength ?? 64,
  temperature: request.temperature,
  randomSeed: request.randomSeed,
  topK: request.topK,
  topP: request.topP,
  tokenBuffer: request.tokenBuffer,
  loraPath: request.loraPath,
  enableThinking: request.enableThinking,
  toolChoice: request.toolChoice,
  systemInstruction: request.systemInstruction,
  maxOutputTokens: request.maxOutputTokens,
);

final class _RecordingHooks extends ChatTurnHooks {
  final calls = <String>[];
  List<Message>? transcript;
  int? tokens;
  bool takeQueryChunks = false;

  @override
  List<Message>? history(InferenceModelSession session) => transcript;

  @override
  int? tokenCount(InferenceModelSession session) => tokens;

  @override
  Future<void>? addQueryChunk(InferenceModelSession session, Message message) {
    if (!takeQueryChunks) return null;
    calls.add('add ${message.text}');
    return session.addQueryChunk(message);
  }

  @override
  Future<void> replayFinished(InferenceModelSession session) async =>
      calls.add('finished');

  @override
  Future<void> replayFailed(
    InferenceModelSession session,
    Object error,
  ) async => calls.add('failed $error');
}

const _tool = Tool(name: 'get_time', description: 'Time.');

void main() {
  group('openSession', () {
    test('reaches openEngineSession with every argument', () async {
      final model = _Model();
      await model.openSession(
        temperature: 0.5,
        randomSeed: 7,
        topK: 3,
        topP: 0.9,
        loraPath: 'l',
        enableVisionModality: true,
        enableAudioModality: false,
        systemInstruction: 's',
        enableThinking: true,
        tools: const [_tool],
        maxOutputTokens: 12,
      );
      final r = model.requests.single;
      expect(
        [
          r.temperature,
          r.randomSeed,
          r.topK,
          r.topP,
          r.loraPath,
          r.enableVisionModality,
          r.enableAudioModality,
          r.systemInstruction,
          r.enableThinking,
          r.tools.single.name,
          r.maxOutputTokens,
          r.modelType,
          r.toolChoice,
        ],
        [
          0.5,
          7,
          3,
          0.9,
          'l',
          true,
          false,
          's',
          true,
          'get_time',
          12,
          null,
          ToolChoice.auto,
        ],
      );
      expect(() => r.tools.add(_tool), throwsUnsupportedError);
    });

    test('an engine without openEngineSession refuses it', () async {
      final model = _BareModel();
      await expectLater(model.openSession(), throwsUnsupportedError);
    });

    test('sessions is the engine\'s, unmodifiable', () async {
      final model = _Model();
      final a = await model.openSession();
      await model.openSession();
      expect(model.sessions, hasLength(2));
      await a.close();
      expect(model.sessions, hasLength(1));
      expect(() => model.sessions.add(a), throwsUnsupportedError);
    });
  });

  group('openChat (D8)', () {
    test('core\'s defaults when the engine resolves nothing itself', () async {
      final model = _Model();
      final chat = await model.openChat();
      expect(chat.modelType, ModelType.gemmaIt);
      expect(chat.supportImage, isFalse);
      expect(chat.supportsFunctionCalls, isFalse);
      expect(chat.maxFunctionBufferLength, defaultMaxFunctionBufferLength);
      expect(model.requests.single.enableVisionModality, isFalse);
    });

    test('the engine\'s own values fill what the caller left unset, and '
        'reach the chat and every session it opens', () async {
      final model = _Model(resolver: _ownDefaults);
      final chat = await model.openChat(
        tools: const [_tool],
        toolChoice: ToolChoice.required,
        systemInstruction: 'sys',
        maxOutputTokens: 9,
      );
      expect(chat.modelType, ModelType.qwen3);
      expect(chat.supportImage, isTrue);
      expect(chat.maxFunctionBufferLength, 64);
      final r = model.requests.single;
      expect(r.modelType, ModelType.qwen3);
      expect(r.toolChoice, ToolChoice.required);
      expect(r.enableVisionModality, isTrue);
      expect(r.systemInstruction, 'sys');
      expect(r.maxOutputTokens, 9);
      expect(r.tools.single.name, 'get_time');

      // A rebuild opens its session through the same request.
      await chat.clearHistory();
      expect(model.requests, hasLength(2));
      expect(model.requests.last.modelType, ModelType.qwen3);
    });

    test('openChat passes sampling, LoRA, thinking and audio to every '
        'session it opens', () async {
      final model = _Model(resolver: _ownDefaults);
      await model.openChat(
        temperature: 0.3,
        randomSeed: 5,
        topK: 2,
        topP: 0.7,
        loraPath: 'adapter',
        enableThinking: true,
        supportAudio: true,
      );
      final r = model.requests.single;
      expect(
        [r.temperature, r.randomSeed, r.topK, r.topP, r.loraPath],
        [0.3, 5, 2, 0.7, 'adapter'],
      );
      expect(r.enableThinking, isTrue);
      expect(r.enableAudioModality, isTrue);
    });

    test('a caller value wins over the engine\'s', () async {
      final model = _Model(resolver: _ownDefaults);
      final chat = await model.openChat(
        modelType: ModelType.gemmaIt,
        supportImage: false,
      );
      expect(chat.modelType, ModelType.gemmaIt);
      expect(chat.supportImage, isFalse);
    });

    test('an engine that refuses the request fails openChat before any '
        'session opens', () async {
      final model = _Model(resolver: (_) => throw ArgumentError('tokenBuffer'));
      await expectLater(model.openChat(), throwsArgumentError);
      expect(model.requests, isEmpty);
    });

    test('runtimeInjectsToolDeclarations: true reaches the chat; false '
        'leaves it to the model\'s format', () async {
      final forced = _Model(
        resolver: (r) => ResolvedChatRequest(
          modelType: ModelType.gemmaIt,
          supportImage: false,
          supportAudio: false,
          supportsFunctionCalls: true,
          tools: r.tools,
          maxFunctionBufferLength: 1024,
          runtimeInjectsToolDeclarations: true,
          temperature: null,
          randomSeed: null,
          topK: null,
          topP: null,
          tokenBuffer: r.tokenBuffer,
          loraPath: null,
          enableThinking: false,
          toolChoice: r.toolChoice,
          systemInstruction: null,
          maxOutputTokens: null,
        ),
      );
      expect((await forced.openChat()).runtimeInjectsToolDeclarations, isTrue);
      final gemma4 = _Model(
        resolver: (r) => _ownDefaults(
          ChatRequest(modelType: ModelType.gemma4, tools: r.tools),
        ),
      );
      final chat = await gemma4.openChat();
      expect(chat.runtimeInjectsToolDeclarations, isTrue);
      final qwen = await _Model(resolver: _ownDefaults).openChat();
      expect(qwen.runtimeInjectsToolDeclarations, isFalse);
    });

    test('the engine\'s hooks drive the chat it opens', () async {
      final hooks = ScriptedTurnHooks(
        () => Stream.value(const TextResponse('scripted')),
      );
      final model = _Model(hooks: hooks);
      final chat = await model.openChat();
      final reply = await chat.generateChatResponse();
      expect((reply as TextResponse).token, 'scripted');
      expect(model.opened.single.turns, 0);
    });
  });

  group('InferenceChat turns', () {
    InferenceChat chatOver(_TurnSession session, {ChatTurnHooks? hooks}) =>
        InferenceChat(
          sessionCreator: () async => session,
          maxTokens: 1024,
          tokenBuffer: 0,
          turnHooks: hooks,
        );

    test('both paths generate through startTurn', () async {
      final session = _TurnSession(tokens: ['Hel', 'lo']);
      final chat = chatOver(session);
      await chat.initSession();
      expect(
        ((await chat.generateChatResponse()) as TextResponse).token,
        'Hello',
      );
      final streamed = await chat.generateChatResponseAsync().toList();
      expect(
        streamed.whereType<TextResponse>().map((r) => r.token).join(),
        'Hello',
      );
      expect(session.turns, 2);
    });

    test('a turn the close ended under the consumer is a StateError on the '
        'stream, after the partial reply is in the history (B90)', () async {
      final session = _TurnSession(tokens: ['Par'], end: TurnEnd.closed);
      final chat = chatOver(session);
      await chat.initSession();
      final seen = <ModelResponse>[];
      await expectLater(
        chat.generateChatResponseAsync().forEach(seen.add),
        throwsStateError,
      );
      expect(seen.single, isA<TextResponse>());
      expect(chat.fullHistory.single.text, 'Par');
    });

    test('the blocking path fails the same way (B90)', () async {
      final session = _TurnSession(tokens: ['Par'], end: TurnEnd.closed);
      final chat = chatOver(session);
      await chat.initSession();
      await expectLater(chat.generateChatResponse(), throwsStateError);
      expect(chat.fullHistory.single.text, 'Par');
    });

    test('a {"message": …} reply is the message, in the stream and in the '
        'history', () async {
      final chat = InferenceChat(
        sessionCreator: () async =>
            _TurnSession(tokens: ['{"message": ', '"hello"}']),
        maxTokens: 1024,
        supportsFunctionCalls: true,
        tools: const [_tool],
      );
      await chat.initSession();
      final streamed = await chat.generateChatResponseAsync().toList();
      expect(streamed.whereType<TextResponse>().single.token, 'hello');
      expect(chat.fullHistory.single.text, 'hello');
    });

    test('a {"message": …} reply that arrives in one chunk is committed as '
        'the message', () async {
      final chat = InferenceChat(
        sessionCreator: () async => _TurnSession(tokens: ['{"message": "hi"}']),
        maxTokens: 1024,
        supportsFunctionCalls: true,
        tools: const [_tool],
      );
      await chat.initSession();
      final streamed = await chat.generateChatResponseAsync().toList();
      expect(streamed.whereType<TextResponse>().single.token, 'hi');
      expect(chat.fullHistory.single.text, 'hi');
    });

    test(
      'reasoning stays out of a blocking reply when thinking is off',
      () async {
        final chat = InferenceChat(
          sessionCreator: () async =>
              _TurnSession(tokens: ['<think>why</think>', 'answer']),
          maxTokens: 1024,
          modelType: ModelType.qwen3,
        );
        await chat.initSession();
        final reply = await chat.generateChatResponse();
        expect((reply as TextResponse).token, 'answer');
        expect(chat.fullHistory.single.text, 'answer');
      },
    );

    test('a stop and the other ends are replies', () async {
      for (final end in TurnEnd.values.where((e) => e != TurnEnd.closed)) {
        final chat = chatOver(_TurnSession(tokens: ['ok'], end: end));
        await chat.initSession();
        final reply = await chat.generateChatResponse();
        expect((reply as TextResponse).token, 'ok', reason: '$end');
      }
    });

    test('a failed token count is the stream\'s error, after the reply is '
        'committed (B80)', () async {
      final session = _TurnSession(tokens: ['ok'])
        ..sizeError = StateError('tokenizer gone');
      final chat = chatOver(session);
      await chat.initSession();
      await expectLater(
        chat.generateChatResponseAsync().toList(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'tokenizer gone',
          ),
        ),
      );
      expect(chat.fullHistory.single.text, 'ok');
    });

    test('a failed rebuild after a full context is the stream\'s error '
        '(B80)', () async {
      var opened = 0;
      final chat = InferenceChat(
        sessionCreator: () async {
          if (opened++ > 0) throw StateError('model closed');
          return _TurnSession(tokens: ['x' * 40]);
        },
        maxTokens: 32,
        tokenBuffer: 0,
      );
      await chat.initSession();
      await expectLater(
        chat.generateChatResponseAsync().toList(),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'model closed'),
        ),
      );
    });

    test(
      'the rebuild after a full context replays the latest reply too',
      () async {
        final sessions = <_TurnSession>[];
        final chat = InferenceChat(
          sessionCreator: () async {
            final s = _TurnSession(tokens: ['answer']);
            sessions.add(s);
            return s;
          },
          // 'answer' (6) fills it; dropping the question (1) is enough.
          maxTokens: 6,
          tokenBuffer: 0,
        );
        await chat.initSession();
        await chat.addQueryChunk(const Message(text: 'q', isUser: true));
        await chat.generateChatResponseAsync().toList();
        expect(sessions, hasLength(2));
        expect(sessions.last.staged.map((m) => m.text), contains('answer'));
      },
    );
  });

  group('ChatTurnHooks', () {
    test(
      'a blocking turn through the hooks leaves reasoning out of its text',
      () async {
        final chat = InferenceChat(
          sessionCreator: () async => _TurnSession(),
          maxTokens: 1024,
          turnHooks: ScriptedTurnHooks(
            () => Stream.fromIterable(const [
              ThinkingResponse('why'),
              TextResponse('answer'),
            ]),
          ),
        );
        await chat.initSession();
        final reply = await chat.generateChatResponse();
        expect((reply as TextResponse).token, 'answer');
      },
    );

    test('the engine\'s token count decides when the chat rebuilds', () async {
      final sessions = <_TurnSession>[];
      final hooks = _RecordingHooks()..tokens = 5000;
      final chat = InferenceChat(
        sessionCreator: () async {
          final s = _TurnSession(tokens: ['a']);
          sessions.add(s);
          return s;
        },
        maxTokens: 1024,
        tokenBuffer: 0,
        turnHooks: hooks,
      );
      await chat.initSession();
      await chat.generateChatResponseAsync().toList();
      expect(sessions, hasLength(2), reason: 'rebuilt on the hook count');
    });

    test('a rebuild replays the engine\'s transcript into the new session '
        'and reports it finished', () async {
      final sessions = <_TurnSession>[];
      const kept = [Message(text: 'q', isUser: true), Message(text: 'a')];
      final hooks = _RecordingHooks()
        ..transcript = kept
        ..tokens = 5000;
      final chat = InferenceChat(
        sessionCreator: () async {
          final s = _TurnSession(tokens: ['a']);
          sessions.add(s);
          return s;
        },
        maxTokens: 1024,
        tokenBuffer: 0,
        turnHooks: hooks,
      );
      await chat.initSession();
      await chat.generateChatResponseAsync().toList();
      expect(sessions.last.staged.map((m) => m.text), ['q', 'a']);
      expect(hooks.calls, ['finished']);
    });

    test('imageMessageCount counts the engine\'s transcript', () async {
      final hooks = _RecordingHooks()
        ..transcript = [
          Message(
            text: 'look',
            isUser: true,
            imageBytes: Uint8List.fromList([1, 2, 3]),
          ),
        ];
      final chat = InferenceChat(
        sessionCreator: () async => _TurnSession(),
        maxTokens: 1024,
        turnHooks: hooks,
      );
      await chat.initSession();
      expect(chat.imageMessageCount, 1);
    });

    test('responses replaces the whole turn on both paths', () async {
      final session = _TurnSession();
      final chat = InferenceChat(
        sessionCreator: () async => session,
        maxTokens: 1024,
        turnHooks: ScriptedTurnHooks(
          () => Stream.fromIterable(const [
            TextResponse('a'),
            FunctionCallResponse(name: 'f', args: {}),
          ]),
        ),
      );
      await chat.initSession();
      expect(await chat.generateChatResponse(), isA<FunctionCallResponse>());
      expect(await chat.generateChatResponseAsync().toList(), hasLength(2));
      expect(session.turns, 0);
      expect(chat.fullHistory, isEmpty);
    });

    test('history, tokenCount and addQueryChunk are the engine\'s when it '
        'gives them', () async {
      final hooks = _RecordingHooks()
        ..transcript = const [Message(text: 'kept', isUser: true)]
        ..tokens = 77
        ..takeQueryChunks = true;
      final session = _TurnSession();
      final chat = InferenceChat(
        sessionCreator: () async => session,
        maxTokens: 1024,
        turnHooks: hooks,
      );
      await chat.initSession();
      await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
      expect(hooks.calls, ['add hi']);
      expect(chat.fullHistory.single.text, 'kept');
      expect(chat.currentTokens, 77);
    });

    test(
      'a replay that finishes calls replayFinished on the new session',
      () async {
        final hooks = _RecordingHooks();
        final chat = InferenceChat(
          sessionCreator: () async => _TurnSession(),
          maxTokens: 1024,
          turnHooks: hooks,
        );
        await chat.initSession();
        await chat.clearHistory(
          replayHistory: const [Message(text: 'a', isUser: true)],
        );
        expect(hooks.calls, ['finished']);
        expect(chat.fullHistory.single.text, 'a');
      },
    );

    test('a replayFinished that throws is a failed replay: the chat starts '
        'over and the error is rethrown', () async {
      final hooks = _ThrowingFinishHooks();
      var opened = 0;
      final chat = InferenceChat(
        sessionCreator: () async {
          opened++;
          return _TurnSession();
        },
        maxTokens: 1024,
        turnHooks: hooks,
      );
      await chat.initSession();
      await expectLater(
        chat.clearHistory(
          replayHistory: const [Message(text: 'a', isUser: true)],
        ),
        throwsA(isA<StateError>()),
      );
      expect(opened, 3);
      expect(chat.fullHistory, isEmpty);
      expect(hooks.failed, isTrue);
    });

    test('a replay that throws leaves the chat empty on a new session, calls '
        'replayFailed, and rethrows', () async {
      final hooks = _RecordingHooks();
      final sessions = <_FailingStageSession>[];
      final chat = InferenceChat(
        sessionCreator: () async {
          final s = _FailingStageSession(
            failOn: sessions.length == 1 ? 'b' : null,
          );
          sessions.add(s);
          return s;
        },
        maxTokens: 1024,
        turnHooks: hooks,
      );
      await chat.initSession();
      await expectLater(
        chat.clearHistory(
          replayHistory: const [
            Message(text: 'a', isUser: true),
            Message(text: 'b', isUser: true),
          ],
        ),
        throwsA(isA<StateError>()),
      );
      expect(sessions, hasLength(3));
      expect(sessions[1].closed, isTrue);
      expect(identical(chat.session, sessions[2]), isTrue);
      expect(chat.fullHistory, isEmpty);
      expect(hooks.calls.single, startsWith('failed'));
    });

    test('a test chat with sessionCreator: null and a noop session runs its '
        'scripted turns', () async {
      final chat = InferenceChat(
        sessionCreator: null,
        maxTokens: 1024,
        turnHooks: ScriptedTurnHooks(
          () => Stream.value(const TextResponse('x')),
        ),
      )..session = NoopSession();
      expect(((await chat.generateChatResponse()) as TextResponse).token, 'x');
    });
  });
}

/// A session whose [addQueryChunk] throws for the message [failOn].
final class _FailingStageSession extends InferenceModelSession {
  _FailingStageSession({this.failOn});

  final String? failOn;
  bool closed = false;

  @override
  Future<void> addQueryChunk(Message message) async {
    if (message.text == failOn) throw StateError('cannot stage $failOn');
  }

  @override
  Future<String> getResponse() async => '';

  @override
  Stream<String> getResponseAsync() => const Stream.empty();

  @override
  Future<int> sizeInTokens(String text) async => 0;

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async => closed = true;
}

/// A model with none of the session SPI: core's defaults apply.
final class _BareModel extends InferenceModel {
  @override
  InferenceModelSession? get session => null;

  @override
  int get maxTokens => 1024;

  @override
  ModelFileType get fileType => ModelFileType.task;

  @override
  PreferredBackend? get activeBackend => null;

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<Tool> tools = const [],
    int? maxOutputTokens,
  }) => throw UnimplementedError();

  @override
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async {}
}

/// Hooks whose [replayFinished] fails, as llama's `commitReplay` can.
final class _ThrowingFinishHooks extends ChatTurnHooks {
  bool failed = false;

  @override
  Future<void> replayFinished(InferenceModelSession session) async =>
      throw StateError('commit failed');

  @override
  Future<void> replayFailed(
    InferenceModelSession session,
    Object error,
  ) async => failed = true;
}
