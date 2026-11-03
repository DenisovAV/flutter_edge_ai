import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// A session whose next turn streams [tokens] and ends with [end]
/// (`endless: true` leaves the end open until [finish]).
final class _Session extends InferenceModelSession {
  _Session({this.tokens = const ['{}'], this.end = TurnEnd.endOfSequence});

  List<String> tokens;
  TurnEnd? end;
  Object? error;
  bool endless = false;
  Completer<TurnEnd>? _open;
  final staged = <Message>[];
  int turns = 0;
  int stops = 0;
  bool closed = false;
  StreamController<String>? live;

  void finish(TurnEnd end) => _open?.complete(end);

  @override
  EngineTurn startTurn() {
    turns++;
    if (endless) {
      final open = _open = Completer<TurnEnd>();
      final controller = live = StreamController<String>();
      for (final token in tokens) {
        controller.add(token);
      }
      controller.onCancel = () {};
      return EngineTurn(text: controller.stream, end: open.future);
    }
    final failure = error;
    final text = failure == null
        ? Stream.fromIterable(tokens)
        : Stream<String>.multi((c) {
            for (final t in tokens) {
              c.add(t);
            }
            c.addError(failure);
            c.close();
          });
    final end = this.end;
    return EngineTurn(text: text, end: end == null ? null : Future.value(end));
  }

  @override
  Stream<String> getResponseAsync() => startTurn().text;

  @override
  Future<String> getResponse() => getResponseAsync().join();

  @override
  Future<int> sizeInTokens(String text) async => text.length;

  @override
  Future<void> addQueryChunk(Message message) async => staged.add(message);

  @override
  Future<void> stopGeneration() async {
    stops++;
    await live?.close();
    finish(TurnEnd.stopped);
  }

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics(outputTokens: 7);

  @override
  Future<void> close() async => closed = true;
}

/// A model that extends [InferenceModel] and enforces [support].
final class _Model extends InferenceModel {
  _Model({this.support, this.refusal, this.hooks, this.resolver});

  /// Null = core's default.
  final StructuredOutputSupport? support;
  final ResponseFormatUnsupportedException? Function(
    JsonSchemaResponseFormat format,
  )?
  refusal;
  final ChatTurnHooks? hooks;
  final ResolvedChatRequest Function(ChatRequest request)? resolver;
  final requests = <SessionRequest>[];
  final opened = <_Session>[];
  int refusalCalls = 0;
  _Session Function()? nextSession;

  @override
  StructuredOutputSupport get engineStructuredOutputSupport =>
      support ?? super.engineStructuredOutputSupport;

  @override
  ResponseFormatUnsupportedException? engineRefusalFor(
    JsonSchemaResponseFormat format,
  ) {
    refusalCalls++;
    return refusal?.call(format);
  }

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
    final session = nextSession?.call() ?? _Session();
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

/// An engine that enforces the whole dialect.
const _all = StructuredOutputSupport(keywords: ResponseFormat.dialect);

final _order = ResponseFormat.jsonSchema({
  'type': 'object',
  'properties': {
    'id': {'type': 'string'},
  },
  'required': ['id'],
});

final class _Hooks extends ChatTurnHooks {
  final seen = <InferenceModelSession>[];
  int responsesCalls = 0;

  @override
  Stream<ModelResponse>? responses(
    InferenceModelSession session, {
    required int tokenBuffer,
  }) {
    responsesCalls++;
    return Stream.value(const TextResponse('hooked'));
  }

  @override
  List<Message>? history(InferenceModelSession session) {
    seen.add(session);
    return null;
  }
}

void main() {
  group('capability', () {
    test('the default refuses every format, with its reason', () {
      final model = _Model();
      expect(model.structuredOutputSupport.isSupported, isFalse);
      final refusal = model.refusalFor(ResponseFormat.jsonObject());
      expect(refusal, isA<ResponseFormatUnsupportedException>());
      expect(refusal!.schemaPath, isNull);
      expect(refusal.message, contains('does not enforce a format'));
    });

    test('an engine keyword outside the dialect is a StateError naming the '
        'engine', () {
      final model = _Model(
        support: const StructuredOutputSupport(keywords: {'type', 'pattern'}),
      );
      expect(
        () => model.structuredOutputSupport,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('_Model'), contains('pattern')),
          ),
        ),
      );
      expect(
        () => model.refusalFor(ResponseFormat.jsonObject()),
        throwsStateError,
      );
    });

    test('the first keyword the engine lacks is refused with its path; '
        'annotations pass', () {
      final model = _Model(
        support: const StructuredOutputSupport(
          keywords: {'type', 'properties', 'required'},
        ),
      );
      expect(
        model.refusalFor(
          ResponseFormat.jsonSchema({
            'type': 'object',
            'title': 'T',
            'properties': {
              'a/b': {'type': 'string', 'description': 'd'},
              'code': {'type': 'string', 'pattern': '^A'},
            },
            'additionalProperties': false,
          }),
        ),
        isA<ResponseFormatUnsupportedException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/properties/code/pattern',
        ),
      );
      expect(
        model.refusalFor(
          ResponseFormat.jsonSchema({
            'type': 'array',
            'items': {'type': 'string', 'maxLength': 3},
          }),
        ),
        isA<ResponseFormatUnsupportedException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/items',
        ),
      );
      expect(model.refusalFor(_order), isNull);
      final arrays = _Model(
        support: const StructuredOutputSupport(keywords: {'type', 'items'}),
      );
      expect(
        arrays.refusalFor(
          ResponseFormat.jsonSchema({
            'type': 'array',
            'items': {'type': 'string', 'maxLength': 3},
          }),
        ),
        isA<ResponseFormatUnsupportedException>().having(
          (e) => e.schemaPath,
          'schemaPath',
          '/items/maxLength',
        ),
      );
    });

    test('engineRefusalFor is asked last, and only when the rest passed', () {
      final none = _Model(refusal: (_) => throw StateError('not reached'));
      expect(none.refusalFor(_order), isNotNull);
      expect(none.refusalCalls, 0);

      final partial = _Model(
        support: const StructuredOutputSupport(keywords: {'type'}),
        refusal: (_) => throw StateError('not reached'),
      );
      expect(partial.refusalFor(_order)!.schemaPath, '/properties');
      expect(partial.refusalCalls, 0);

      const budget = ResponseFormatUnsupportedException(
        'A model loaded with a thinkingTokenBudget refuses formats.',
      );
      final engine = _Model(support: _all, refusal: (_) => budget);
      expect(engine.refusalFor(_order), same(budget));
      expect(engine.refusalCalls, 1);
    });
  });

  group('openSession(responseFormat:)', () {
    test('a refused format throws before the engine is called', () async {
      final model = _Model();
      await expectLater(
        model.openSession(responseFormat: _order),
        throwsA(isA<ResponseFormatUnsupportedException>()),
      );
      expect(model.requests, isEmpty);
    });

    test('engineRefusalFor refuses before the engine is called', () async {
      final model = _Model(
        support: _all,
        refusal: (_) => const ResponseFormatUnsupportedException('budget'),
      );
      await expectLater(
        model.openSession(responseFormat: _order),
        throwsA(isA<ResponseFormatUnsupportedException>()),
      );
      expect(model.requests, isEmpty);
    });

    test('tools or thinking with a format are ArgumentErrors, before the '
        'refusal', () async {
      for (final model in [_Model(), _Model(support: _all)]) {
        await expectLater(
          model.openSession(
            responseFormat: _order,
            tools: const [Tool(name: 't', description: 'd')],
          ),
          throwsArgumentError,
        );
        await expectLater(
          model.openSession(responseFormat: _order, enableThinking: true),
          throwsArgumentError,
        );
        expect(model.requests, isEmpty);
      }
    });

    test('without a format the engine session is returned as it is', () async {
      final model = _Model();
      final session = await model.openSession(
        tools: const [Tool(name: 't', description: 'd')],
        enableThinking: true,
      );
      expect(session, same(model.opened.single));
      expect(model.requests.single.responseFormat, isNull);
      expect(model.sessions, [session]);
    });

    test('with a format the engine gets it, and sessions lists core\'s '
        'session', () async {
      final model = _Model(support: _all);
      final session = await model.openSession(responseFormat: _order);
      expect(model.requests.single.responseFormat, _order);
      expect(session, isNot(same(model.opened.single)));
      expect(model.sessions, [same(session)]);
      await session.close();
      expect(model.opened.single.closed, isTrue);
      expect(model.sessions, isEmpty);
    });

    test('a conforming reply is delivered unchanged', () async {
      final model = _Model(support: _all)
        ..nextSession = () => _Session(tokens: ['{"id"', ': "A"}']);
      final session = await model.openSession(responseFormat: _order);
      expect(await session.getResponseAsync().toList(), ['{"id"', ': "A"}']);
      expect(await session.getResponse(), '{"id": "A"}');
      expect(session.getSessionMetrics().outputTokens, 7);
    });

    test(
      'a turn that did not end the reply is incomplete, after its text',
      () async {
        for (final end in [
          TurnEnd.outputLimit,
          TurnEnd.contextLimit,
          TurnEnd.stopped,
          TurnEnd.closed,
        ]) {
          final model = _Model(support: _all)
            ..nextSession = () => _Session(tokens: ['{"id": "A"}'], end: end);
          final session = await model.openSession(responseFormat: _order);
          final (chunks, errors) = await _drain(session.getResponseAsync());
          final error = errors.single;
          expect(chunks, ['{"id": "A"}'], reason: end.name);
          expect(
            error,
            isA<IncompleteStructuredOutputException>()
                .having((e) => e.end, 'end', end)
                .having((e) => e.partialText, 'partialText', '{"id": "A"}'),
            reason: end.name,
          );
          await expectLater(
            session.getResponse(),
            throwsA(isA<IncompleteStructuredOutputException>()),
          );
        }
      },
    );

    test('a complete reply that is not a value of the format is '
        'non-conforming', () async {
      final model = _Model(support: _all)
        ..nextSession = () => _Session(tokens: ['{"name": "A"}']);
      final session = await model.openSession(responseFormat: _order);
      await expectLater(
        session.getResponse(),
        throwsA(
          isA<NonConformingStructuredOutputException>()
              .having((e) => e.schemaPath, 'schemaPath', '/required')
              .having((e) => e.text, 'text', '{"name": "A"}'),
        ),
      );
    });

    test('a turn with no end is a StateError naming the engine', () async {
      final model = _Model(support: _all)
        ..nextSession = () => _Session(end: null);
      final session = await model.openSession(responseFormat: _order);
      await expectLater(
        session.getResponse(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('_Model'), contains('EngineTurn.end is null')),
          ),
        ),
      );
    });

    test('the engine\'s own error is passed on, and the reply not checked '
        'after it', () async {
      final model = _Model(support: _all)
        ..nextSession = () =>
            _Session(tokens: ['{'], end: TurnEnd.outputLimit)
              ..error = StateError('engine failed');
      final session = await model.openSession(responseFormat: _order);
      final (_, errors) = await _drain(session.getResponseAsync());
      expect(errors, [isA<StateError>()]);
    });

    test('a cancelled subscription stops the engine, and the next turn waits '
        'for the end', () async {
      final engine = _Session(tokens: ['{"id"'])..endless = true;
      final model = _Model(support: _all)..nextSession = () => engine;
      final session = await model.openSession(responseFormat: _order);
      final first = Completer<void>();
      final subscription = session.getResponseAsync().listen(
        (_) => first.isCompleted ? null : first.complete(),
      );
      await first.future;
      await subscription.cancel();
      expect(engine.stops, 1);

      engine
        ..endless = false
        ..tokens = ['{"id": "B"}'];
      expect(await session.getResponse(), '{"id": "B"}');
      expect(engine.turns, 2);
    });

    test('a second turn does not start before the first has ended', () async {
      final engine = _Session(tokens: ['{"id": "A"}'])..endless = true;
      final model = _Model(support: _all)..nextSession = () => engine;
      final session = await model.openSession(responseFormat: _order);
      final firstReply = session.getResponse();
      await pumpEventQueue();
      engine.endless = false;
      final secondReply = session.getResponse();
      await pumpEventQueue();
      expect(engine.turns, 1);
      await engine.live!.close();
      engine.finish(TurnEnd.endOfSequence);
      expect(await firstReply, '{"id": "A"}');
      expect(await secondReply, '{"id": "A"}');
      expect(engine.turns, 2);
    });
  });

  group('openChat(responseFormat:)', () {
    test(
      'a refused format fails openChat before the engine is called',
      () async {
        final model = _Model();
        await expectLater(
          model.openChat(responseFormat: _order),
          throwsA(isA<ResponseFormatUnsupportedException>()),
        );
        expect(model.requests, isEmpty);
      },
    );

    test('tools are refused as the caller passed them, even when the engine '
        'would drop them', () async {
      final model = _Model(
        support: _all,
        resolver: (r) => _carry(r, tools: const []),
      );
      await expectLater(
        model.openChat(
          responseFormat: _order,
          tools: const [Tool(name: 't', description: 'd')],
        ),
        throwsArgumentError,
      );
      await expectLater(
        model.openChat(responseFormat: _order, enableThinking: true),
        throwsArgumentError,
      );
      expect(model.requests, isEmpty);
    });

    test('a plain chat has no format; a structured one reads it from its '
        'session', () async {
      final model = _Model(support: _all);
      expect((await model.openChat()).responseFormat, isNull);
      final chat = await model.openChat(responseFormat: _order);
      expect(chat.responseFormat, _order);
      expect(model.requests.last.responseFormat, _order);
      expect(model.sessions, contains(same(chat.session)));
    });

    test('a chat over a session that enforces nothing claims no format', () {
      final chat = InferenceChat(sessionCreator: null, maxTokens: 1024)
        ..session = _Session();
      expect(chat.responseFormat, isNull);
    });

    test('a structured turn runs core\'s path, not the hooks', () async {
      final hooks = _Hooks();
      final model = _Model(support: _all, hooks: hooks)
        ..nextSession = () => _Session(tokens: ['{"id": "A"}']);
      final chat = await model.openChat(responseFormat: _order);
      await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
      expect(
        await chat.generateChatResponse(),
        isA<TextResponse>().having((r) => r.token, 'token', '{"id": "A"}'),
      );
      expect(await chat.generateChatResponseAsync().toList(), [
        isA<TextResponse>(),
      ]);
      expect(hooks.responsesCalls, 0);
      expect(chat.fullHistory.map((m) => m.text), [
        'Hi',
        '{"id": "A"}',
        '{"id": "A"}',
      ]);
      // The hooks get the engine's own session, never core's.
      expect(hooks.seen, isNotEmpty);
      expect(hooks.seen.toSet(), {same(model.opened.single)});
    });

    test('a failed reply is committed to the history, then thrown', () async {
      for (final (tokens, end, matcher) in [
        (
          ['{"id": '],
          TurnEnd.outputLimit,
          isA<IncompleteStructuredOutputException>(),
        ),
        (
          ['{"id": 1}'],
          TurnEnd.endOfSequence,
          isA<NonConformingStructuredOutputException>(),
        ),
        (
          ['{"id": "A"}'],
          TurnEnd.closed,
          isA<IncompleteStructuredOutputException>(),
        ),
      ]) {
        final model = _Model(support: _all)
          ..nextSession = () => _Session(tokens: tokens, end: end);
        final chat = await model.openChat(responseFormat: _order);
        await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
        await expectLater(chat.generateChatResponse(), throwsA(matcher));
        expect(chat.fullHistory.last.text, tokens.join(), reason: end.name);
        expect(chat.fullHistory.last.isUser, isFalse);

        await chat.addQueryChunk(const Message(text: 'Again', isUser: true));
        final streamed = <ModelResponse>[];
        await expectLater(
          chat.generateChatResponseAsync().forEach(streamed.add),
          throwsA(matcher),
        );
        expect(streamed, [isA<TextResponse>()]);
        expect(chat.fullHistory.last.text, tokens.join());
      }
    });

    test('a rebuilt session keeps the format', () async {
      final model = _Model(support: _all);
      final chat = await model.openChat(responseFormat: _order);
      await chat.clearHistory(
        replayHistory: const [Message(text: 'Hi', isUser: true)],
      );
      expect(model.requests, hasLength(2));
      expect(model.requests.map((r) => r.responseFormat), [_order, _order]);
      expect(chat.responseFormat, _order);
      expect(model.opened.last.staged.single.text, 'Hi');
    });
  });
}

/// Every value of [request], with [tools] in place of its own.
ResolvedChatRequest _carry(ChatRequest request, {required List<Tool> tools}) =>
    ResolvedChatRequest(
      modelType: request.modelType ?? ModelType.gemmaIt,
      supportImage: false,
      supportAudio: false,
      supportsFunctionCalls: false,
      tools: tools,
      maxFunctionBufferLength: 64,
      temperature: request.temperature,
      randomSeed: request.randomSeed,
      topK: request.topK,
      topP: request.topP,
      tokenBuffer: request.tokenBuffer,
      loraPath: request.loraPath,
      enableThinking: false,
      toolChoice: request.toolChoice,
      systemInstruction: request.systemInstruction,
      maxOutputTokens: request.maxOutputTokens,
      responseFormat: request.responseFormat,
    );

/// Every chunk and every error of [stream], once it is done.
Future<(List<String>, List<Object>)> _drain(Stream<String> stream) async {
  final chunks = <String>[];
  final errors = <Object>[];
  final done = Completer<void>();
  stream.listen(chunks.add, onError: errors.add, onDone: done.complete);
  await done.future;
  return (chunks, errors);
}
