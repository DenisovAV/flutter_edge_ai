// The session is now a translator, not a transport: buffering, streaming,
// cancellation and token counting all live in flutter_local_ai, and what is
// left here is turning a flutter_edge_ai [Message] into the text and images a
// [LocalAiSession] takes. These tests drive the fake host end to end so the
// translation is checked against what actually reaches the platform.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/message.dart' show Message;
import 'package:flutter_edge_ai/core/registry/runtime_config.dart'
    show RuntimeConfig;
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart'
    show BuiltInAiEngine;
import 'package:flutter_edge_ai_builtin_ai/src/builtin_ai_model.dart'
    show BuiltInAiModel;
import 'package:flutter_edge_ai_builtin_ai/src/builtin_ai_session.dart'
    show BuiltInAiSession;
import 'package:flutter_local_ai/flutter_local_ai.dart'
    show
        LocalAiGenerationException,
        LocalAiSession,
        LocalAiTokenizerUnavailable,
        debugLocalAiHost;
import 'package:flutter_local_ai/testing.dart' show FakeLocalAiHost;
import 'package:flutter_test/flutter_test.dart';

import 'adapter_test_support.dart';

const _visionConfig = RuntimeConfig(
  maxTokens: 4096,
  modelPath: '',
  supportImage: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLocalAiHost host;

  /// Swaps in [fake] for the rest of the test, so the suite starts from the
  /// plain fake and upgrades to a double only where it needs one. Every host
  /// installed is disposed, including one that was replaced mid-test.
  void install(FakeLocalAiHost fake) {
    host = fake;
    debugLocalAiHost = fake;
    addTearDown(fake.dispose);
  }

  setUp(() => install(FakeLocalAiHost()));

  tearDown(() => debugLocalAiHost = null);

  Future<BuiltInAiSession> newSession([
    RuntimeConfig config = builtInConfig,
  ]) async {
    final model =
        await const BuiltInAiEngine().createModel(builtInSpec(), config)
            as BuiltInAiModel;
    addTearDown(model.close);
    return await model.createSession() as BuiltInAiSession;
  }

  test('a failed close can be retried', () async {
    final model =
        await const BuiltInAiEngine().createModel(builtInSpec(), builtInConfig)
            as BuiltInAiModel;
    addTearDown(model.close);
    final session = await model.createSession();
    host.closeSessionError = StateError('teardown failed');

    await expectLater(session.close(), throwsStateError);
    expect(model.session, same(session));

    host.closeSessionError = null;
    await session.close();
    expect(model.session, isNull);
  });

  test('getResponse returns the host string', () async {
    host.response = 'Hello from Nano';
    final session = await newSession();

    expect(await session.getResponse(), 'Hello from Nano');
  });

  test('getResponseAsync yields partials, filters foreign sessionId, closes '
      'on done', () async {
    final session = await newSession();
    final id = session.localAiSession.sessionId;

    final chunks = <String>[];
    final done = session.getResponseAsync().listen(chunks.add).asFuture<void>();
    await pumpEventQueue();

    // Another session's output — must never reach this stream.
    host.emitToken(id + 1, 'X');
    host.emitToken(id, 'Hel');
    host.emitToken(id, 'lo');
    host.emitDone(id);
    await done;

    expect(chunks, ['Hel', 'lo']);
  });

  test('an error event surfaces as a stream error', () async {
    final session = await newSession();
    final id = session.localAiSession.sessionId;

    final errors = <Object>[];
    // Not `asFuture`: it replaces the subscription's onError handler, so the
    // error would escape as an unhandled future error instead of landing here.
    final closed = Completer<void>();
    session.getResponseAsync().listen(
      (_) {},
      onError: errors.add,
      onDone: closed.complete,
    );
    await pumpEventQueue();

    host.emitError(id, 'boom');
    await closed.future;

    expect(
      errors.single,
      isA<LocalAiGenerationException>().having(
        (e) => e.message,
        'message',
        'boom',
      ),
    );
  });

  test('sizeInTokens returns the host value', () async {
    host.countTokensResult = 42;
    final session = await newSession();

    expect(await session.sizeInTokens('some text'), 42);
  });

  test('sizeInTokens falls back to (len/4).ceil() when the host has no '
      'tokenizer', () async {
    host.countTokensError = LocalAiTokenizerUnavailable('no tokenizer here');
    final session = await newSession();

    // 'abcdefg' -> 7 chars -> ceil(7/4) = 2
    expect(await session.sizeInTokens('abcdefg'), 2);
  });

  test('stopGeneration reaches the host', () async {
    final session = await newSession();

    await session.stopGeneration();

    expect(host.calls, contains('stopGeneration'));
  });

  test('metrics are empty rather than invented', () async {
    final session = await newSession();

    // Built-in OS models expose no benchmark counters; sizeInTokens is the
    // one number that is real.
    final metrics = session.getSessionMetrics();
    expect(metrics.totalTokens, 0);
    expect(metrics.tokensPerSecond, isNull);
  });

  group('message adaptation', () {
    test('a text message reaches the host transcript', () async {
      final session = await newSession();

      await session.addQueryChunk(const Message(text: 'Hello!', isUser: true));

      expect(
        host.session(session.localAiSession.sessionId)!.transcript.toString(),
        contains('Hello!'),
      );
    });

    test('an image message calls addImage before addQueryChunk', () async {
      install(TurnOrderHost());
      final session = await newSession(_visionConfig);
      final bytes = Uint8List.fromList([1, 2, 3, 4]);

      await session.addQueryChunk(
        Message.withImage(text: 'describe', imageBytes: bytes, isUser: true),
      );

      // Images first, so the host has them buffered before the text that
      // refers to them — the ordering the native multimodal requests expect.
      expect((host as TurnOrderHost).turnCalls, ['addImage', 'addQueryChunk']);
      final fake = host.session(session.localAiSession.sessionId)!;
      expect(fake.images, [bytes]);
      expect(fake.transcript.toString(), contains('describe'));
    });

    test('an image is refused when vision was never enabled', () async {
      final session = await newSession();

      await expectLater(
        session.addQueryChunk(
          Message.withImage(
            text: 'describe',
            imageBytes: Uint8List.fromList([1]),
            isUser: true,
          ),
        ),
        throwsUnsupportedError,
      );
      // Refused outright rather than sent as bare text.
      expect(
        host.session(session.localAiSession.sessionId)!.transcript.toString(),
        isEmpty,
      );
    });

    test('audio is refused rather than silently dropped', () async {
      final session = await newSession();

      await expectLater(
        session.addQueryChunk(
          Message.audioOnly(audioBytes: Uint8List.fromList([1]), isUser: true),
        ),
        throwsUnsupportedError,
      );
      expect(
        host.session(session.localAiSession.sessionId)!.transcript.toString(),
        isEmpty,
      );
    });

    test('maxNumImages is enforced before any image is sent', () async {
      final session = await newSession(
        const RuntimeConfig(
          maxTokens: 4096,
          modelPath: '',
          supportImage: true,
          maxNumImages: 1,
        ),
      );

      await expectLater(
        session.addQueryChunk(
          Message.withImages(
            text: 'Compare',
            imageBytes: [Uint8List(1), Uint8List(1)],
            isUser: true,
          ),
        ),
        throwsArgumentError,
      );
      expect(host.session(session.localAiSession.sessionId)!.images, isEmpty);
    });
  });

  group('escape hatch', () {
    test(
      'localAiSession exposes the underlying flutter_local_ai session',
      () async {
        final session = await newSession();

        expect(session.localAiSession, isA<LocalAiSession>());
        expect(host.session(session.localAiSession.sessionId), isNotNull);
      },
    );

    test(
      'schema-constrained output stays reachable through localAiSession',
      () async {
        final session = await newSession();
        // flutter_edge_ai's InferenceModelSession has no slot for structured
        // output, so this is the documented way to reach it.
        host.response = '{"value":"found"}';

        await session.localAiSession.addQueryChunk('Look up the value');
        final json = await session.localAiSession.getStructuredResponse({
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
          },
        });

        expect(json, '{"value":"found"}');
        expect(
          host.session(session.localAiSession.sessionId)!.lastSchemaJson,
          contains('value'),
        );
      },
    );
  });
}
