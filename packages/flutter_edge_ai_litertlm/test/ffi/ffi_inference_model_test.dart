// The decider SPI (OptionScorer, DeciderUnsupportedException) is @experimental;
// openOptionScorer is @protected (core's decider calls it), and these tests
// call it directly.
// ignore_for_file: experimental_member_use, invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/litertlm_decision_section.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../litertlm_container_fixture.dart';

void main() {
  test('FfiInferenceModel exposes the backend initialized by the runtime', () {
    final model = FfiInferenceModel(
      ffiClient: LiteRtLmFfiClient(),
      maxTokens: 2048,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.gpu,
      onClose: () {},
    );

    expect(model.activeBackend, PreferredBackend.gpu);
  });

  group('readDecisionSection', () {
    FfiInferenceModel modelWith(LitetuneDecisionRead? read) =>
        FfiInferenceModel(
          ffiClient: LiteRtLmFfiClient(),
          maxTokens: 2048,
          modelType: ModelType.gemmaIt,
          activeBackend: PreferredBackend.cpu,
          decisionRead: read,
          onClose: () {},
        );

    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ffi_decision'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('returns the payload read when the model was loaded', () async {
      const payload = '{"contract_version":1}';
      final file = File('${dir.path}/model.litertlm')
        ..writeAsBytesSync(
          litertlmContainer(
            [(type: 1, modelType: null, bytes: utf8.encode(payload))],
            items: {
              0: {'name': litetuneDecisionSectionName},
            },
          ),
        );
      final read = await LitetuneDecisionRead.read(file.path);
      expect(await modelWith(read).readDecisionSection(), payload);
    });

    test('rethrows the error the load-time read captured', () async {
      final read = await LitetuneDecisionRead.read(
        '${dir.path}/missing.litertlm',
      );
      await expectLater(
        modelWith(read).readDecisionSection(),
        throwsA(same(read.error)),
      );
    });

    test('a model built without reading its file refuses by name', () async {
      await expectLater(
        modelWith(null).readDecisionSection(),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            startsWith('This model was built without reading its file'),
          ),
        ),
      );
    });
  });

  group('openOptionScorer', () {
    FfiInferenceModel modelOn(PreferredBackend? backend) => FfiInferenceModel(
      ffiClient: LiteRtLmFfiClient(),
      maxTokens: 2048,
      modelType: ModelType.gemmaIt,
      activeBackend: backend,
      onClose: () {},
    );

    for (final backend in [PreferredBackend.cpu, PreferredBackend.gpu]) {
      test('opens a scorer on ${backend.name}', () async {
        final scorer = await modelOn(backend).openOptionScorer();
        expect(scorer, isA<OptionScorer>());
        await scorer.close();
      });
    }

    test('refuses the NPU by name', () async {
      await expectLater(
        modelOn(PreferredBackend.npu).openOptionScorer(),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('NPU'), contains('rolls back one token only')),
          ),
        ),
      );
    });

    test('refuses a model that does not report its backend', () async {
      await expectLater(
        modelOn(null).openOptionScorer(),
        throwsA(
          isA<DeciderUnsupportedException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('does not report its backend'),
              contains('PreferredBackend.cpu'),
            ),
          ),
        ),
      );
    });
  });

  test('isClosed is true from the moment close() starts', () async {
    // Core's getActiveModel cache checks this: its close listener fires only
    // once the teardown has ended.
    final model = FfiInferenceModel(
      ffiClient: LiteRtLmFfiClient(),
      maxTokens: 2048,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
      onClose: () {},
    );
    expect(model.isClosed, isFalse);

    final closing = model.close();
    expect(model.isClosed, isTrue);
    await closing;
  });

  test(
    'a failed close remains retryable and notifies only after success',
    () async {
      final client = _FailingShutdownClient();
      var legacyCloses = 0;
      var listenerCloses = 0;
      final model = FfiInferenceModel(
        ffiClient: client,
        maxTokens: 2048,
        modelType: ModelType.gemmaIt,
        activeBackend: PreferredBackend.cpu,
        onClose: () => legacyCloses++,
      )..addCloseListener(() => listenerCloses++);

      await expectLater(model.close(), throwsA(isA<TimeoutException>()));
      expect(client.attempts, 1);
      expect(legacyCloses, 0);
      expect(listenerCloses, 0);

      await model.close();
      expect(client.attempts, 2);
      expect(legacyCloses, 1);
      expect(listenerCloses, 1);
    },
  );
}

final class _FailingShutdownClient extends LiteRtLmFfiClient {
  int attempts = 0;

  @override
  Future<void> shutdown() async {
    attempts++;
    if (attempts == 1) throw TimeoutException('native turn did not end');
  }
}
