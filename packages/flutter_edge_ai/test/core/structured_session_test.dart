import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/src/chat.dart' show chatTurnErrorEndTimeout;
import 'package:flutter_edge_ai/src/interface.dart' show startEngineTurn;
import 'package:flutter_edge_ai/src/structured/structured_session.dart'
    show structuredTurnErrorEndTimeout;
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

  /// Thrown by the next startTurn.
  Object? startError;

  /// The end future fails instead of completing (a contract breach).
  bool endFails = false;

  /// The end completes only when the test calls [finish]: not at a cancel
  /// of the text, not at a stop (an engine whose end lags its stop).
  bool lateEnd = false;

  /// The end of an endless turn has already completed while its text is
  /// still open (a contract breach: the turn is over).
  bool endEarly = false;

  /// What sizeInTokens returns; null = the text's length.
  int? sizeOverride;

  /// Thrown by sizeInTokens; [sizeCalls] counts the calls.
  Object? sizeError;
  int sizeCalls = 0;

  /// When set, stopGeneration returns only once it completes; [stopLandedOn]
  /// is the turn count when it did.
  Completer<void>? stopGate;
  int? stopLandedOn;
  Object? stopError;

  void finish(TurnEnd end) {
    if (!(_open?.isCompleted ?? true)) _open!.complete(end);
  }

  @override
  EngineTurn startTurn() {
    if (startError case final error?) throw error;
    turns++;
    if (endFails) {
      return EngineTurn(
        text: Stream.fromIterable(tokens),
        end: Future.error(StateError('end failed')),
      );
    }
    if (endless) {
      final open = _open = Completer<TurnEnd>();
      if (endEarly) open.complete(TurnEnd.endOfSequence);
      final controller = live = StreamController<String>();
      for (final token in tokens) {
        controller.add(token);
      }
      // The contract: the end completes when the consumer cancels the text.
      controller.onCancel = () {
        // Also called once a closed controller's done is delivered.
        if (!controller.isClosed && !lateEnd) finish(TurnEnd.stopped);
      };
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
  Future<int> sizeInTokens(String text) async {
    sizeCalls++;
    if (sizeError case final error?) throw error;
    return sizeOverride ?? text.length;
  }

  @override
  Future<void> addQueryChunk(Message message) async => staged.add(message);

  @override
  Future<void> stopGeneration() async {
    stops++;
    if (stopError case final error?) throw error;
    await live?.close();
    if (!lateEnd) finish(TurnEnd.stopped);
    if (stopGate case final gate?) {
      await gate.future;
      stopLandedOn = turns;
    }
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
          isA<IncompleteStructuredOutputException>()
              .having((e) => e.end, 'end', TurnEnd.outputLimit)
              .having((e) => e.partialText, 'partialText', '{"id": '),
        ),
        (
          ['{"id": 1}'],
          TurnEnd.endOfSequence,
          isA<NonConformingStructuredOutputException>()
              .having((e) => e.schemaPath, 'schemaPath', '/properties/id/type')
              .having((e) => e.text, 'text', '{"id": 1}'),
        ),
        (
          ['{"id": "A"}'],
          TurnEnd.closed,
          isA<IncompleteStructuredOutputException>()
              .having((e) => e.end, 'end', TurnEnd.closed)
              .having((e) => e.partialText, 'partialText', '{"id": "A"}'),
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

  group('a structured turn\'s lifecycle', () {
    Future<(_Session, InferenceModelSession)> open(_Session engine) async {
      final model = _Model(support: _all)..nextSession = () => engine;
      return (engine, await model.openSession(responseFormat: _order));
    }

    test('a startTurn that throws fails the turn; the next one runs', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id": "A"}'])..startError = StateError('boom'),
      );
      await expectLater(
        session.getResponse(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'boom')),
      );
      engine.startError = null;
      expect(await session.getResponse(), '{"id": "A"}');
    });

    test('after a turn with no end, the next turn runs', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id": "A"}'], end: null),
      );
      await expectLater(session.getResponse(), throwsStateError);
      engine.end = TurnEnd.endOfSequence;
      expect(await session.getResponse(), '{"id": "A"}');
      expect(engine.turns, 2);
    });

    test('an end that fails is the turn\'s error, not a hang', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id": "A"}'])..endFails = true,
      );
      await expectLater(
        session.getResponse().timeout(const Duration(seconds: 5)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('_Model'), contains('end completed with an error')),
          ),
        ),
      );
      engine.endFails = false;
      expect(await session.getResponse(), '{"id": "A"}');
    });

    test('a turn cancelled while queued never reaches the engine', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id": "A"}'])..endless = true,
      );
      final first = session.getResponse();
      await pumpEventQueue();
      final queued = session.getResponseAsync().listen((_) {});
      await pumpEventQueue();
      await queued.cancel();
      engine.endless = false;
      await engine.live!.close();
      engine.finish(TurnEnd.endOfSequence);
      expect(await first, '{"id": "A"}');
      await pumpEventQueue();
      expect(engine.turns, 1);
      expect(await session.getResponse(), '{"id": "A"}');
      expect(engine.turns, 2);
    });

    test(
      'the next turn waits for a cancelled turn\'s stop to return',
      () async {
        final gate = Completer<void>();
        final (engine, session) = await open(
          _Session(tokens: ['{"id"'])
            ..endless = true
            ..stopGate = gate,
        );
        final first = Completer<void>();
        final subscription = session.getResponseAsync().listen(
          (_) => first.isCompleted ? null : first.complete(),
        );
        await first.future;
        // The end completes at the cancel; the stop returns only later.
        final cancelled = subscription.cancel();
        engine
          ..endless = false
          ..tokens = ['{"id": "B"}'];
        final next = session.getResponse();
        await pumpEventQueue();
        expect(engine.turns, 1);
        gate.complete();
        await cancelled;
        expect(await next, '{"id": "B"}');
        expect(engine.stopLandedOn, 1);
        expect(engine.turns, 2);
      },
    );

    test('a stop that throws on cancel neither escapes nor blocks the next '
        'turn', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id"'])
          ..endless = true
          ..stopError = StateError('stop failed'),
      );
      final first = Completer<void>();
      final subscription = session.getResponseAsync().listen(
        (_) => first.isCompleted ? null : first.complete(),
      );
      await first.future;
      await subscription.cancel();
      expect(engine.stops, 1);
      engine
        ..endless = false
        ..stopError = null
        ..tokens = ['{"id": "B"}'];
      expect(await session.getResponse(), '{"id": "B"}');
    });

    test('a failed text that never closes ends the turn within '
        'structuredTurnErrorEndTimeout; the engine is stopped', () async {
      final previous = structuredTurnErrorEndTimeout;
      structuredTurnErrorEndTimeout = const Duration(milliseconds: 50);
      addTearDown(() => structuredTurnErrorEndTimeout = previous);
      final (engine, session) = await open(
        _Session(tokens: ['{"id"'])..endless = true,
      );
      final turn = startEngineTurn(session);
      final drained = _drain(turn.text);
      await pumpEventQueue();
      engine.live!.addError(StateError('stuck'));
      final (chunks, errors) = await drained.timeout(
        const Duration(seconds: 5),
      );
      expect(chunks, ['{"id"']);
      expect(errors, [
        isA<StateError>().having((e) => e.message, 'message', 'stuck'),
      ]);
      expect(await turn.end, TurnEnd.stopped);
      expect(engine.stops, 1);

      engine
        ..endless = false
        ..tokens = ['{"id": "B"}'];
      expect(await session.getResponse(), '{"id": "B"}');
      expect(engine.turns, 2);
    });

    test('the bound stops the engine even when the consumer paused after '
        'the error', () async {
      final previous = structuredTurnErrorEndTimeout;
      structuredTurnErrorEndTimeout = const Duration(milliseconds: 50);
      addTearDown(() => structuredTurnErrorEndTimeout = previous);
      final (engine, session) = await open(
        _Session(tokens: ['{"id"'])..endless = true,
      );
      late final StreamSubscription<String> subscription;
      subscription = session.getResponseAsync().listen(
        (_) {},
        // Paused with the error in hand: the done the bound sends waits, so
        // only the bound itself can let the engine's text go.
        onError: (Object _) => subscription.pause(),
      );
      await pumpEventQueue();
      engine.live!.addError(StateError('stuck'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.stops, 1);
      await subscription.cancel();
    });

    test('a paused consumer pauses the engine\'s text', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id"'])..endless = true,
      );
      final subscription = session.getResponseAsync().listen((_) {});
      subscription.pause();
      await pumpEventQueue();
      expect(engine.live!.isPaused, isTrue);
      subscription.resume();
      await pumpEventQueue();
      expect(engine.live!.isPaused, isFalse);
      await subscription.cancel();
    });

    test('stopGeneration reaches the engine', () async {
      final (engine, session) = await open(_Session());
      await session.stopGeneration();
      expect(engine.stops, 1);
    });

    test('startTurn on core\'s session reports the engine\'s end', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id"'], end: TurnEnd.outputLimit),
      );
      final turn = startEngineTurn(session);
      final (_, errors) = await _drain(turn.text);
      expect(errors.single, isA<IncompleteStructuredOutputException>());
      expect(await turn.end, TurnEnd.outputLimit);

      engine.endless = true;
      final first = startEngineTurn(session);
      final queued = startEngineTurn(session);
      final firstSub = first.text.listen((_) {});
      await pumpEventQueue();
      final queuedSub = queued.text.listen((_) {});
      await queuedSub.cancel();
      await firstSub.cancel();
      expect(await first.end, TurnEnd.stopped);
      expect(await queued.end, TurnEnd.stopped);
    });
  });

  group('a structured chat turn\'s failures', () {
    Future<(_Model, InferenceChat)> chatOver(_Session engine) async {
      final model = _Model(support: _all)..nextSession = () => engine;
      final chat = await model.openChat(responseFormat: _order);
      await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
      return (model, chat);
    }

    test(
      'an engine\'s refusal at the first send reaches the app unchanged',
      () async {
        const refusal = ResponseFormatUnsupportedException(
          'Failed to create LLGuidance constraint',
        );
        final engine = _Session(tokens: const [])
          ..error = refusal
          ..sizeError = StateError('session closed');
        final (_, chat) = await chatOver(engine);
        await expectLater(chat.generateChatResponse(), throwsA(same(refusal)));
        expect(engine.sizeCalls, 0);
        // The engine failed the turn: its staged message is taken back.
        expect(chat.fullHistory, isEmpty);
      },
    );

    test('an engine error takes the turn back on both paths; a format '
        'failure keeps it', () async {
      for (final streamed in [false, true]) {
        Future<void> turn(InferenceChat chat, Matcher matcher) => expectLater(
          streamed
              ? chat.generateChatResponseAsync().drain<void>()
              : chat.generateChatResponse(),
          throwsA(matcher),
        );

        // The context window refused the input: taken back.
        const tooLong = ContextLimitException('too long');
        final refused = _Session(tokens: const [], end: TurnEnd.contextLimit)
          ..error = tooLong;
        final (_, first) = await chatOver(refused);
        final tokensBefore = first.currentTokens;
        await turn(first, same(tooLong));
        expect(first.fullHistory, isEmpty, reason: 'streamed: $streamed');
        expect(first.currentTokens, lessThanOrEqualTo(tokensBefore));

        // Another engine error, after some text: taken back too.
        final failing = _Session(tokens: ['{"id"'])
          ..error = StateError('engine failed');
        final (_, second) = await chatOver(failing);
        await turn(second, isA<StateError>());
        expect(second.fullHistory, isEmpty, reason: 'streamed: $streamed');

        // The format's failures: the message and the reply stay.
        for (final (tokens, end) in [
          (['{"id"'], TurnEnd.outputLimit),
          (['{"id": 1}'], TurnEnd.endOfSequence),
        ]) {
          final (_, chat) = await chatOver(_Session(tokens: tokens, end: end));
          await turn(chat, isA<StructuredOutputException>());
          expect(chat.fullHistory.map((m) => m.text), [
            'Hi',
            tokens.join(),
          ], reason: '${end.name}, streamed: $streamed');
        }
      }
    });

    test('a failed text that never closes ends the structured turn within '
        'chatTurnErrorEndTimeout, taken back', () async {
      final previous = chatTurnErrorEndTimeout;
      chatTurnErrorEndTimeout = const Duration(milliseconds: 50);
      addTearDown(() => chatTurnErrorEndTimeout = previous);
      for (final streamed in [false, true]) {
        final engine = _Session(tokens: ['{"id"'])..endless = true;
        final (_, chat) = await chatOver(engine);
        final reply = streamed
            ? chat.generateChatResponseAsync().drain<void>()
            : chat.generateChatResponse();
        await pumpEventQueue();
        engine.live!.addError(StateError('stuck'));
        await expectLater(
          reply.timeout(const Duration(seconds: 5)),
          throwsA(
            isA<StateError>().having((e) => e.message, 'message', 'stuck'),
          ),
        );
        expect(chat.fullHistory, isEmpty, reason: 'streamed: $streamed');
        // The turn let the engine's text go: core's session stopped it.
        await pumpEventQueue();
        expect(engine.stops, 1, reason: 'streamed: $streamed');
      }
    });

    test('after a committed structured turn, an engine failure takes back '
        'only its own turn', () async {
      for (final streamed in [false, true]) {
        final engine = _Session(tokens: ['{"id": "A"}']);
        final model = _Model(support: _all)..nextSession = () => engine;
        final chat = await model.openChat(responseFormat: _order);
        await chat.addQueryChunk(const Message(text: 'q1', isUser: true));
        await chat.generateChatResponse();
        engine.error = StateError('engine failed');
        await chat.addQueryChunk(const Message(text: 'q2', isUser: true));
        await expectLater(
          streamed
              ? chat.generateChatResponseAsync().drain<void>()
              : chat.generateChatResponse(),
          throwsA(isA<StateError>()),
        );
        // Turn 1 cleared what it staged: turn 2 takes back q2 alone.
        expect(chat.fullHistory.map((m) => m.text), [
          'q1',
          '{"id": "A"}',
        ], reason: 'streamed: $streamed');
      }
    });

    test('a structured turn stopped before any text is taken back, as a '
        'plain one is', () async {
      for (final streamed in [false, true]) {
        final engine = _Session(tokens: const [], end: TurnEnd.stopped);
        final (_, chat) = await chatOver(engine);
        await expectLater(
          streamed
              ? chat.generateChatResponseAsync().drain<void>()
              : chat.generateChatResponse(),
          throwsA(
            isA<IncompleteStructuredOutputException>()
                .having((e) => e.end, 'end', TurnEnd.stopped)
                .having((e) => e.partialText, 'partialText', ''),
          ),
        );
        expect(chat.fullHistory, isEmpty, reason: 'streamed: $streamed');
        // Taken back: nothing is counted, and no rebuild can follow.
        expect(engine.sizeCalls, 0, reason: 'streamed: $streamed');
      }
    });

    test(
      'an empty structured turn that was not stopped keeps its message',
      () async {
        for (final end in [TurnEnd.closed, TurnEnd.contextLimit]) {
          final (_, chat) = await chatOver(
            _Session(tokens: const [], end: end),
          );
          await expectLater(
            chat.generateChatResponse(),
            throwsA(
              isA<IncompleteStructuredOutputException>()
                  .having((e) => e.end, 'end', end)
                  .having((e) => e.partialText, 'partialText', ''),
            ),
          );
          expect(chat.fullHistory.map((m) => m.text), ['Hi'], reason: end.name);
        }
      },
    );

    test('a plain turn stopped with only empty chunks is taken back', () async {
      final model = _Model()
        ..nextSession = () =>
            _Session(tokens: const ['', ''], end: TurnEnd.stopped);
      final chat = await model.openChat();
      await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
      await chat.generateChatResponse();
      expect(chat.fullHistory, isEmpty);
    });

    test('a stopped structured turn keeps its message (a stop is not the '
        'engine failing)', () async {
      final (_, chat) = await chatOver(
        _Session(tokens: ['{"id"'], end: TurnEnd.stopped),
      );
      await expectLater(
        chat.generateChatResponse(),
        throwsA(
          isA<IncompleteStructuredOutputException>().having(
            (e) => e.end,
            'end',
            TurnEnd.stopped,
          ),
        ),
      );
      expect(chat.fullHistory.map((m) => m.text), ['Hi', '{"id"']);
    });

    test(
      'a failed token count does not replace the format\'s failure',
      () async {
        for (final (tokens, end, matcher) in [
          (
            ['{"id": 1}'],
            TurnEnd.endOfSequence,
            isA<NonConformingStructuredOutputException>()
                .having(
                  (e) => e.schemaPath,
                  'schemaPath',
                  '/properties/id/type',
                )
                .having((e) => e.text, 'text', '{"id": 1}'),
          ),
          (
            ['{"id"'],
            TurnEnd.outputLimit,
            isA<IncompleteStructuredOutputException>()
                .having((e) => e.end, 'end', TurnEnd.outputLimit)
                .having((e) => e.partialText, 'partialText', '{"id"'),
          ),
        ]) {
          final engine = _Session(tokens: tokens, end: end)
            ..sizeError = StateError('count failed');
          final (_, chat) = await chatOver(engine);
          await expectLater(chat.generateChatResponse(), throwsA(matcher));
          expect(engine.sizeCalls, 1, reason: end.name);
          expect(chat.fullHistory.last.text, tokens.join());
        }
      },
    );

    test('a reply cut by a close is committed but not counted', () async {
      final engine = _Session(tokens: ['{"id"'], end: TurnEnd.closed);
      final (_, chat) = await chatOver(engine);
      await expectLater(
        chat.generateChatResponse(),
        throwsA(
          isA<IncompleteStructuredOutputException>().having(
            (e) => e.end,
            'end',
            TurnEnd.closed,
          ),
        ),
      );
      expect(engine.sizeCalls, 0);
      expect(chat.fullHistory.last.text, '{"id"');
    });

    test('structured replies are counted, conforming or not', () async {
      final engine = _Session(tokens: ['{"id": "A"}']);
      final (_, chat) = await chatOver(engine);
      final before = chat.currentTokens;
      await chat.generateChatResponse();
      expect(chat.currentTokens, before + '{"id": "A"}'.length);
      engine
        ..tokens = ['{"id"']
        ..end = TurnEnd.outputLimit;
      await chat.addQueryChunk(const Message(text: 'Again', isUser: true));
      final middle = chat.currentTokens;
      await expectLater(
        chat.generateChatResponse(),
        throwsA(isA<IncompleteStructuredOutputException>()),
      );
      expect(chat.currentTokens, greaterThanOrEqualTo(middle + 5));
    });
  });

  group('a failed rebuild after a failed structured reply', () {
    test('the format failure is the turn\'s error; the rebuild\'s is thrown '
        'by the next turn, until clearHistory', () async {
      final engine = _Session(tokens: ['{"id": 1}'])..sizeOverride = 2000;
      final model = _Model(support: _all)..nextSession = () => engine;
      final chat = await model.openChat(responseFormat: _order);
      await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
      final rebuildError = StateError('rebuild failed');
      model.nextSession = () => throw rebuildError;
      await expectLater(
        chat.generateChatResponse(),
        throwsA(
          isA<NonConformingStructuredOutputException>().having(
            (e) => e.schemaPath,
            'schemaPath',
            '/properties/id/type',
          ),
        ),
      );
      expect(engine.closed, isTrue);
      final stagedBefore = engine.staged.length;

      await expectLater(
        chat.addQueryChunk(const Message(text: 'Again', isUser: true)),
        throwsA(same(rebuildError)),
      );
      await expectLater(
        chat.generateChatResponse(),
        throwsA(same(rebuildError)),
      );
      await expectLater(
        chat.generateChatResponseAsync().drain<void>(),
        throwsA(same(rebuildError)),
      );
      expect(engine.staged, hasLength(stagedBefore));
      expect(engine.turns, 1);

      final fresh = _Session(tokens: ['{"id": "A"}']);
      model.nextSession = () => fresh;
      await chat.clearHistory();
      await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
      expect(
        await chat.generateChatResponse(),
        isA<TextResponse>().having((r) => r.token, 'token', '{"id": "A"}'),
      );
    });
  });

  test('a single-turn model\'s failed rebuild is kept the same way', () async {
    final engine = _Session(tokens: ['{"id"'], end: TurnEnd.outputLimit);
    final model = _Model(support: _all)..nextSession = () => engine;
    final chat = await model.openChat(
      responseFormat: _order,
      modelType: ModelType.functionGemma,
    );
    await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
    final rebuildError = StateError('rebuild failed');
    model.nextSession = () => throw rebuildError;
    await expectLater(
      chat.generateChatResponse(),
      throwsA(
        isA<IncompleteStructuredOutputException>().having(
          (e) => e.end,
          'end',
          TurnEnd.outputLimit,
        ),
      ),
    );
    await expectLater(
      chat.addQueryChunk(const Message(text: 'Again', isUser: true)),
      throwsA(same(rebuildError)),
    );
  });

  group('review follow-ups: the cancelled turn', () {
    Future<(_Session, InferenceModelSession)> open(_Session engine) async {
      final model = _Model(support: _all)..nextSession = () => engine;
      return (engine, await model.openSession(responseFormat: _order));
    }

    test('the next turn waits for an end that lags the stop', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id"'])
          ..endless = true
          ..lateEnd = true,
      );
      final first = Completer<void>();
      final subscription = session.getResponseAsync().listen(
        (_) => first.isCompleted ? null : first.complete(),
      );
      await first.future;
      final cancelled = subscription.cancel();
      await pumpEventQueue();
      expect(engine.stops, 1);
      engine
        ..endless = false
        ..lateEnd = false
        ..tokens = ['{"id": "B"}'];
      final next = session.getResponse();
      await pumpEventQueue();
      expect(engine.turns, 1);
      engine.finish(TurnEnd.stopped);
      await cancelled;
      expect(await next, '{"id": "B"}');
      expect(engine.turns, 2);
    });

    test('a turn whose end came already is not stopped on cancel', () async {
      final (engine, session) = await open(
        _Session(tokens: ['{"id"'])
          ..endless = true
          ..endEarly = true,
      );
      final first = Completer<void>();
      final subscription = session.getResponseAsync().listen(
        (_) => first.isCompleted ? null : first.complete(),
      );
      await first.future;
      await pumpEventQueue();
      await subscription.cancel();
      expect(engine.stops, 0);
    });

    test('a turn that failed to start reports closed', () async {
      final (engine, session) = await open(
        _Session()..startError = StateError('boom'),
      );
      final failedStart = startEngineTurn(session);
      await _drain(failedStart.text);
      expect(await failedStart.end, TurnEnd.closed);

      engine
        ..startError = null
        ..end = null;
      final noEnd = startEngineTurn(session);
      await _drain(noEnd.text);
      expect(await noEnd.end, TurnEnd.closed);
    });
  });

  group('the hooks of a structured chat', () {
    test('every hook gets the engine\'s own session', () async {
      final hooks = _SessionRecordingHooks();
      final model = _Model(support: _all, hooks: hooks)
        ..nextSession = () => _Session(tokens: ['{"id": "A"}']);
      final chat = await model.openChat(responseFormat: _order);
      await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));
      await chat.generateChatResponse();
      await chat.clearHistory(
        replayHistory: const [Message(text: 'Hi', isUser: true)],
      );
      await expectLater(
        chat.clearHistory(
          replayHistory: const [Message(text: 'boom', isUser: true)],
        ),
        throwsStateError,
      );
      expect(hooks.calls.keys, {
        'addQueryChunk',
        'tokenCount',
        'replayFinished',
        'replayFailed',
      });
      for (final MapEntry(key: hook, value: sessions) in hooks.calls.entries) {
        expect(sessions, everyElement(isA<_Session>()), reason: hook);
      }
    });
  });

  group('openChat\'s order', () {
    test('a refused format never reaches resolveChatRequest', () async {
      var resolved = 0;
      ResolvedChatRequest resolver(ChatRequest r) {
        resolved++;
        return _carry(r, tools: r.tools);
      }

      for (final model in [
        _Model(resolver: resolver),
        _Model(
          support: _all,
          resolver: resolver,
          refusal: (_) => const ResponseFormatUnsupportedException('budget'),
        ),
      ]) {
        await expectLater(
          model.openChat(responseFormat: _order),
          throwsA(isA<ResponseFormatUnsupportedException>()),
        );
        expect(model.requests, isEmpty);
      }
      expect(resolved, 0);
    });

    test(
      'an engine that changes the format is a StateError naming it',
      () async {
        final dropping = _Model(
          support: _all,
          resolver: (r) => _carry(r, tools: r.tools, responseFormat: null),
        );
        await expectLater(
          dropping.openChat(responseFormat: _order),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('_Model'), contains('responseFormat')),
            ),
          ),
        );
        expect(dropping.requests, isEmpty);

        final adding = _Model(
          support: _all,
          resolver: (r) => _carry(r, tools: r.tools, responseFormat: _order),
        );
        await expectLater(adding.openChat(), throwsStateError);

        // An equal copy is the same format.
        final copying = _Model(
          support: _all,
          resolver: (r) => _carry(
            r,
            tools: r.tools,
            responseFormat:
                ResponseFormat.jsonSchema(
                      (_order as JsonSchemaResponseFormat).schema,
                    )
                    as JsonSchemaResponseFormat,
          ),
        );
        final chat = await copying.openChat(responseFormat: _order);
        expect(
          identical(copying.requests.single.responseFormat, _order),
          isTrue,
        );
        expect(chat.responseFormat, _order);
      },
    );
  });

  group('refusal paths', () {
    test('JSON Pointer tokens escape ~ and / in refusals', () {
      final model = _Model(
        support: const StructuredOutputSupport(
          keywords: {'type', 'properties'},
        ),
      );
      expect(
        model
            .refusalFor(
              ResponseFormat.jsonSchema({
                'type': 'object',
                'properties': {
                  'a/b~c': {'type': 'string', 'pattern': 'x'},
                },
              }),
            )!
            .schemaPath,
        '/properties/a~1b~0c/pattern',
      );
      expect(
        model
            .refusalFor(
              ResponseFormat.jsonSchema({'type': 'object', 'x/y~': 1}),
            )!
            .schemaPath,
        '/x~1y~0',
      );
    });

    test('the reported keyword set cannot be changed', () {
      final model = _Model(
        support: StructuredOutputSupport(keywords: {'type'}),
      );
      expect(
        () => model.structuredOutputSupport.keywords.add('pattern'),
        throwsUnsupportedError,
      );
    });
  });
}

/// Every value of [request], with [tools] in place of its own, and
/// [responseFormat] in place of its own when given.
ResolvedChatRequest _carry(
  ChatRequest request, {
  required List<Tool> tools,
  Object? responseFormat = _keep,
}) => ResolvedChatRequest(
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
  responseFormat: identical(responseFormat, _keep)
      ? request.responseFormat
      : responseFormat as JsonSchemaResponseFormat?,
);

const _keep = Object();

/// Records the session each hook receives; a queued message `boom` throws.
final class _SessionRecordingHooks extends ChatTurnHooks {
  final calls = <String, List<InferenceModelSession>>{};

  void _record(String hook, InferenceModelSession session) =>
      (calls[hook] ??= []).add(session);

  @override
  Future<void>? addQueryChunk(InferenceModelSession session, Message message) {
    _record('addQueryChunk', session);
    if (message.text == 'boom') return Future.error(StateError('boom'));
    return null;
  }

  @override
  int? tokenCount(InferenceModelSession session) {
    _record('tokenCount', session);
    return null;
  }

  @override
  Future<void> replayFinished(InferenceModelSession session) async =>
      _record('replayFinished', session);

  @override
  Future<void> replayFailed(
    InferenceModelSession session,
    Object error,
  ) async => _record('replayFailed', session);
}

/// Every chunk and every error of [stream], once it is done.
Future<(List<String>, List<Object>)> _drain(Stream<String> stream) async {
  final chunks = <String>[];
  final errors = <Object>[];
  final done = Completer<void>();
  stream.listen(chunks.add, onError: errors.add, onDone: done.complete);
  await done.future;
  return (chunks, errors);
}
