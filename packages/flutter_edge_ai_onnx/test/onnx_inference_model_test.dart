// This suite covers the legacy singleton lane and its open-session coexistence.
// ignore_for_file: deprecated_member_use

// Fake-backed unit tests for OnnxInferenceModel — zero dlopen (hardened
// plan Phase 3, Task 6).
import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/onnx_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_gen_ai_client.dart';

OnnxInferenceModel _model(FakeGenAiClient client, {void Function()? onClose}) {
  return OnnxInferenceModel(
    client: client,
    maxTokens: 1024,
    modelType: ModelType.gemmaIt,
    activeBackend: PreferredBackend.cpu,
    onClose: onClose ?? () {},
  );
}

Future<Map<String, Object>> _searchOptionsOf(
  FakeGenAiClient client,
  OnnxInferenceModel model,
) async {
  await model.session!.addQueryChunk(const Message(text: 'Hi', isUser: true));
  await model.session!.getResponse();
  return client.generateCalls.last.searchOptions;
}

void main() {
  group('sampling reaches the generator', () {
    test('values the caller sets become ORT-GenAI search options', () async {
      final client = FakeGenAiClient();
      final model = _model(client);
      await model.createSession(temperature: 0.7, topK: 20, randomSeed: 3);
      expect(await _searchOptionsOf(client, model), {
        'do_sample': true,
        'temperature': 0.7,
        'top_k': 20,
        'random_seed': 3,
      });
    });

    test('nothing set leaves the model config alone', () async {
      final client = FakeGenAiClient();
      final model = _model(client);
      await model.createSession();
      expect(await _searchOptionsOf(client, model), isEmpty);
    });

    test('an invalid value throws before the live session is closed', () async {
      final client = FakeGenAiClient();
      final model = _model(client);
      final live = await model.createSession();

      await expectLater(model.createSession(topP: 0), throwsArgumentError);
      expect(model.session, same(live));
      expect(client.resetSessionCalls, 0);
    });
  });

  group('createSession singleton lane', () {
    test(
      'a second sequential createSession closes the first session',
      () async {
        final client = FakeGenAiClient();
        final model = _model(client);

        final first = await model.createSession();
        final second = await model.createSession();

        expect(identical(first, second), isFalse);
        expect(model.session, same(second));
        // The first session's close() reached the client via resetSession().
        expect(client.resetSessionCalls, greaterThanOrEqualTo(1));
      },
    );

    test(
      'concurrent createSession callers share one in-flight future',
      () async {
        final client = FakeGenAiClient();
        final model = _model(client);

        final futureA = model.createSession();
        final futureB = model.createSession();

        final results = await Future.wait([futureA, futureB]);
        expect(identical(results[0], results[1]), isTrue);
      },
    );

    test('loraPath throws UnsupportedError', () async {
      final client = FakeGenAiClient();
      final model = _model(client);

      expect(
        () => model.createSession(loraPath: '/tmp/lora.bin'),
        throwsUnsupportedError,
      );
    });

    test('vision/audio modality request throws UnsupportedError', () async {
      final client = FakeGenAiClient();
      final model = _model(client);

      expect(
        () => model.createSession(enableVisionModality: true),
        throwsUnsupportedError,
      );
      expect(
        () => model.createSession(enableAudioModality: true),
        throwsUnsupportedError,
      );
    });
  });

  group('openSession', () {
    Future<InferenceModelSession> open(OnnxInferenceModel m) => m.openSession();

    test('returns independent sessions, each with its own id', () async {
      final client = FakeGenAiClient();
      final model = _model(client);
      final legacy = await model.createSession();
      final a = await open(model);
      final b = await open(model);

      expect(model.session, same(legacy));
      expect(model.sessions, [legacy, a, b]);

      await a.addQueryChunk(const Message(text: 'A', isUser: true));
      await a.getResponse();
      await b.addQueryChunk(const Message(text: 'B', isUser: true));
      await b.getResponse();
      await legacy.addQueryChunk(const Message(text: 'L', isUser: true));
      await legacy.getResponse();

      final ids = client.generateCalls.map((t) => t.sessionId).toList();
      expect(ids[0], isNotNull);
      expect(ids[1], isNotNull);
      expect(ids[0], isNot(ids[1]));
      expect(ids[2], isNull);
      // Each session's first turn creates its own generator.
      expect(client.generateCalls.every((t) => t.isFirstTurn), isTrue);
    });

    test('metrics are the session\'s own, not another one\'s', () async {
      final client = FakeGenAiClient(chunksToEmit: const ['x']);
      final model = _model(client);
      final a = await open(model);
      final b = await open(model);
      await a.addQueryChunk(const Message(text: 'aaaa', isUser: true));
      await a.getResponse();

      expect(a.getSessionMetrics().outputTokens, 1);
      expect(b.getSessionMetrics().outputTokens, 0);
    });

    test(
      'closing a session resets its generator only, never the legacy one',
      () async {
        final client = FakeGenAiClient();
        final model = _model(client);
        final legacy = await model.createSession();
        final a = await open(model);
        await a.addQueryChunk(const Message(text: 'A', isUser: true));
        await a.getResponse();
        final id = client.generateCalls.single.sessionId;

        await a.close();

        expect(client.stoppedSessions, [id]);
        expect(client.resetSessions, [id]);
        expect(model.sessions, [legacy]);
      },
    );

    test('maxConcurrentSessions caps open sessions with a StateError, and '
        'closing one frees a slot', () async {
      final model = OnnxInferenceModel(
        client: FakeGenAiClient(),
        maxTokens: 1024,
        modelType: ModelType.gemmaIt,
        activeBackend: PreferredBackend.cpu,
        maxConcurrentSessions: 2,
        onClose: () {},
      );
      // The legacy session does not count against the cap.
      await model.createSession();
      final a = await open(model);
      await open(model);

      await expectLater(model.openSession(), throwsStateError);

      await a.close();
      await open(model);
    });

    test('rejects what the legacy session rejects', () async {
      final model = _model(FakeGenAiClient());
      expect(() => model.openSession(loraPath: '/x'), throwsUnsupportedError);
      expect(
        () => model.openSession(enableVisionModality: true),
        throwsUnsupportedError,
      );
      await expectLater(model.openSession(topP: 0), throwsArgumentError);
      expect(model.sessions, isEmpty);
    });

    test('closing the model closes every open session', () async {
      final client = FakeGenAiClient();
      final model = _model(client);
      await model.createSession();
      await open(model);
      await open(model);

      await model.close();

      expect(model.sessions, isEmpty);
      await expectLater(model.openSession(), throwsStateError);
    });

    test('openChat takes the model\'s own type, not Gemma\'s (D8)', () async {
      final model = OnnxInferenceModel(
        client: FakeGenAiClient(),
        maxTokens: 1024,
        modelType: ModelType.phi,
        activeBackend: PreferredBackend.cpu,
        onClose: () {},
      );
      final chat = await model.openChat();
      expect(chat.modelType, ModelType.phi);
      expect(chat.supportImage, isFalse);
      await chat.close();
      final asked = await model.openChat(modelType: ModelType.qwen3);
      expect(asked.modelType, ModelType.qwen3);
      await asked.close();
    });

    test('openChat runs on an opened session', () async {
      final client = FakeGenAiClient();
      final model = _model(client);
      final chat = await model.openChat();
      expect(model.sessions, hasLength(1));
      await chat.close();
    });
  });

  group('close', () {
    test(
      'is idempotent and fires CloseNotifier listeners exactly once',
      () async {
        final client = FakeGenAiClient();
        final model = _model(client);
        await model.createSession();

        var fired = 0;
        model.addCloseListener(() => fired++);

        await model.close();
        await model.close();

        expect(fired, 1);
        expect(client.shutdownCalls, 1);
      },
    );

    test('closes the live session before shutting down the client', () async {
      final client = FakeGenAiClient();
      final model = _model(client);
      await model.createSession();
      expect(model.session, isNotNull);

      await model.close();

      expect(model.session, isNull);
    });

    test('isClosed is true from the moment close() starts', () async {
      // Core's getActiveModel cache checks this: its close listener fires
      // only once the teardown has ended.
      final model = _model(FakeGenAiClient());
      expect(model.isClosed, isFalse);

      final closing = model.close();
      expect(model.isClosed, isTrue);
      await closing;
    });

    test('createSession after close throws StateError', () async {
      final client = FakeGenAiClient();
      final model = _model(client);
      await model.close();

      expect(() => model.createSession(), throwsStateError);
    });

    test('a throwing client shutdown still fires the close listeners, and '
        'only the first close() reports it', () async {
      final client = FakeGenAiClient()
        ..shutdownError = StateError('shutdown failed');
      var onCloseCalls = 0;
      var listenerCalls = 0;
      final model = _model(client, onClose: () => onCloseCalls++);
      model.addCloseListener(() => listenerCalls++);

      await expectLater(
        model.close(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'shutdown failed',
          ),
        ),
      );
      expect(onCloseCalls, 1);
      expect(listenerCalls, 1, reason: 'core evicts on the listener');
      await model.close();
      expect(listenerCalls, 1);
      expect(client.shutdownCalls, 1);
    });

    test('when shutdown and onClose both throw, close() reports the shutdown '
        'error and prints the other one', () async {
      final client = FakeGenAiClient()
        ..shutdownError = StateError('shutdown failed');
      var listenerCalls = 0;
      final model = _model(
        client,
        onClose: () => throw StateError('onClose failed'),
      );
      model.addCloseListener(() => listenerCalls++);
      final printed = <String>[];

      await runZoned(
        () => expectLater(
          model.close(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'shutdown failed',
            ),
          ),
        ),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      expect(listenerCalls, 1, reason: 'core evicts on the listener');
      expect(
        printed,
        contains(contains('onClose failed')),
        reason: 'the second failure was lost',
      );
    });
  });
}
