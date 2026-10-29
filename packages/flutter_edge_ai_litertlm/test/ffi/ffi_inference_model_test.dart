// The decider SPI (OptionScorer, DeciderUnsupportedException) is @experimental.
// ignore_for_file: experimental_member_use

import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('refuses the NPU by name', () {
      expect(
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

    test('refuses a model that does not report its backend', () {
      expect(
        modelOn(null).openOptionScorer(),
        throwsA(isA<DeciderUnsupportedException>()),
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
}
