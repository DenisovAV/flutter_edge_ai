// Fake-backed unit tests for OnnxInferenceModel — zero dlopen (hardened
// plan Phase 3, Task 6).
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_edge_ai/core/model.dart';
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

void main() {
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
    test(
      'is not supported (v1) — inherits the base UnsupportedError',
      () async {
        final client = FakeGenAiClient();
        final model = _model(client);

        expect(() => model.openSession(), throwsUnsupportedError);
      },
    );
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
  });
}
