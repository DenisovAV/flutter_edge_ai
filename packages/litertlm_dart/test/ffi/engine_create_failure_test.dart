import 'package:litertlm_dart/src/ffi/engine_create_failure.dart';
import 'package:litertlm_dart/src/bundle/litertlm_bundle_activation.dart'
    show GpuActivationReason;
import 'package:test/test.dart';

/// What LiteRT-LM reported on Windows for gemma-4-E2B-it-gpu.litertlm.
const _artisanRefusal =
    'NOT_FOUND: No available engine for backend: GPU_ARTISAN. Preferred '
    'engine types: [kAdvancedLegacyTfLite, kLegacyTfLite]. Available '
    '(registered) engine types: [kAdvancedLiteRTCompiledModel].';

String _message({
  String backend = 'gpu',
  String? nativeMessage = 'INTERNAL: out of memory',
  int? activationDataType,
  GpuActivationReason? reason,
}) => engineCreateFailureMessage(
  backend: backend,
  modelPath: '/m/model.litertlm',
  nativeMessage: nativeMessage,
  activationDataType: activationDataType,
  gpuActivationReason: reason,
);

void main() {
  group('GPU-artisan build', () {
    test('is named, with a CompiledModel build as the way out', () {
      final message = _message(nativeMessage: _artisanRefusal);
      expect(message, contains('GPU-artisan build'));
      expect(message, contains('open-source LiteRT-LM runtime'));
      expect(message, contains('any native platform'));
      expect(message, contains('CPU/GPU CompiledModel backends'));
      expect(message, contains('the generic file beside them'));
      expect(message, contains('/m/model.litertlm'));
      expect(message, isNot(startsWith('Failed to create engine')));
    });

    test('gets no float32 hint, whatever ran at float32', () {
      for (final reason in [null, ...GpuActivationReason.values]) {
        final message = _message(
          nativeMessage: _artisanRefusal,
          activationDataType: 0,
          reason: reason,
        );
        expect(message, contains('GPU-artisan build'));
        expect(message, isNot(contains('float32')));
        expect(message, isNot(contains('ActivationDataType')));
      }
    });

    test('is matched on every backend and in other spellings', () {
      for (final native in [
        _artisanRefusal,
        'No available engine for backend: GPU_ARTISAN',
        'no available engine for backend GPU_ARTISAN.',
        'NOT_FOUND:  No  available engine for backend:\n gpu_artisan; more',
      ]) {
        expect(isGpuArtisanRefusal(native), isTrue, reason: native);
        for (final backend in ['gpu', 'cpu', 'npu']) {
          expect(
            _message(backend: backend, nativeMessage: native),
            contains('GPU-artisan build'),
          );
        }
      }
    });

    test('is not matched on other refusals', () {
      for (final native in [
        null,
        '',
        'NOT_FOUND: No available engine for backend: GPU. Preferred engine '
            'types: [kAdvancedLiteRTCompiledModel]',
        'NOT_FOUND: No available engine for backend: GPU_ARTISANAL',
        'GPU_ARTISAN',
      ]) {
        expect(isGpuArtisanRefusal(native), isFalse, reason: native);
        expect(
          _message(nativeMessage: native),
          startsWith('Failed to create engine on gpu'),
        );
      }
    });
  });

  group('float32 hint', () {
    test('a caller who set float32 is told to try without it', () {
      final message = _message(activationDataType: 0);
      expect(
        message,
        startsWith(
          'Failed to create engine on gpu: INTERNAL: out of memory. '
          'Model: /m/model.litertlm (float32 activations need more GPU '
          'memory',
        ),
      );
      expect(message, contains('activationDataType asked for float32'));
      expect(message, contains('try without it'));
      expect(message, contains('ActivationDataType.float16 asks for the'));
      expect(message, isNot(contains('FunctionGemma')));
      expect(message, isNot(contains('Gemma 4')));
    });

    test('FunctionGemma without the key names the missing key', () {
      final message = _message(
        activationDataType: 0,
        reason: GpuActivationReason.functionGemmaWithoutKey,
      );
      expect(message, contains('the engine chose float32'));
      expect(
        message,
        contains('FunctionGemma bundle declares no prefer_activation_type'),
      );
      expect(message, contains('ActivationDataType.float16 asks for the'));
      expect(message, isNot(contains('Gemma 4')));
      expect(message, isNot(contains('try without it')));
    });

    test('Gemma 4 above 2,048 tokens names the context', () {
      final message = _message(
        activationDataType: 0,
        reason: GpuActivationReason.gemma4LongContext,
      );
      expect(message, contains('the engine chose float32'));
      expect(
        message,
        contains('Gemma 4 with a context (maxTokens) above 2048'),
      );
      expect(message, contains('a maxTokens of 2048 or less'));
      expect(message, contains('ActivationDataType.float16'));
      expect(message, isNot(contains('FunctionGemma')));
      expect(message, isNot(contains('prefer_activation_type')));
      expect(message, isNot(contains('try without it')));
    });

    test('is not given off the GPU or at float16', () {
      for (final (backend, type) in [
        ('cpu', 0),
        ('npu', 0),
        ('gpu', 1),
        ('gpu', null),
      ]) {
        final message = _message(
          backend: backend,
          activationDataType: type,
          reason: GpuActivationReason.gemma4LongContext,
        );
        expect(
          message,
          'Failed to create engine on $backend: INTERNAL: out of memory. '
          'Model: /m/model.litertlm',
        );
      }
    });

    test('no native message leaves no colon', () {
      expect(
        _message(nativeMessage: null),
        'Failed to create engine on gpu. Model: /m/model.litertlm',
      );
    });
  });

  group('stream failure', () {
    // The S25 Ultra (Adreno 830) failure of a float32 Gemma 4 turn.
    const s25 =
        'INTERNAL: ERROR: [third_party/odml/litert_lm/runtime/executor/'
        'llm_litert_compiled_model_executor.cc] Failed to invoke the compiled '
        'model';

    String stream({
      String error = s25,
      String? backend = 'gpu',
      int? activationDataType = 0,
      GpuActivationReason? reason,
      bool android = false,
    }) => streamFailureMessage(
      nativeError: error,
      backend: backend,
      activationDataType: activationDataType,
      gpuActivationReason: reason,
      android: android,
    );

    test('a float32 GPU turn that failed in the compiled model names float32 '
        'and the way to float16 or the CPU', () {
      for (final reason in [null, ...GpuActivationReason.values]) {
        final message = stream(reason: reason);
        expect(message, startsWith('Stream error: $s25'));
        expect(message, contains('float32 activations on the GPU'));
        expect(message, contains('Invalid work group size'));
        expect(message, contains('PreferredBackend.cpu'));
        expect(message, isNot(contains('the default')));
      }
      expect(stream(), contains('activationDataType asked for float32'));
      expect(stream(), contains('ActivationDataType.float16'));
      final g4 = stream(reason: GpuActivationReason.gemma4LongContext);
      expect(g4, contains('the engine chose float32 because Gemma 4'));
      expect(g4, contains('maxTokens of 2048 or less'));
      expect(g4, contains('degrades'));
      final fg = stream(reason: GpuActivationReason.functionGemmaWithoutKey);
      expect(fg, contains('answers with nothing'));
      expect(
        fg,
        isNot(contains('ActivationDataType.float16')),
        reason: 'float16 is what this bundle cannot run at',
      );
      expect(
        stream(error: 'INTERNAL: something else'),
        contains('float32 activations on the GPU'),
      );
    });

    test('on Android, a GPU turn that failed in the compiled model at any '
        'other activation names the Adreno work-group limits and the CPU', () {
      // The Galaxy A05s (Adreno 610) failure of a float16 Gemma 4 turn.
      for (final activation in [null, 1]) {
        final message = stream(activationDataType: activation, android: true);
        expect(message, startsWith('Stream error: $s25 ('));
        expect(message, contains('Invalid work group size'));
        expect(message, contains('LiteRT #12075'));
        expect(message, contains('PreferredBackend.cpu'));
        expect(message, isNot(contains('float32')));
      }
      // float32 keeps its own wording on Android too.
      final fp32 = stream(android: true);
      expect(fp32, contains('float32 activations on the GPU'));
      expect(fp32, isNot(contains('#12075')));
      for (final message in [
        stream(activationDataType: 1, android: true, backend: 'cpu'),
        stream(activationDataType: null, android: true, backend: null),
        stream(
          activationDataType: 1,
          android: true,
          error: 'RESOURCE_EXHAUSTED: context full',
        ),
        stream(
          activationDataType: 1,
          android: true,
          error: 'RESOURCE_EXHAUSTED: Failed to invoke the compiled model',
        ),
      ]) {
        expect(message, isNot(contains('(')), reason: message);
      }
    });

    test('is left bare off float32, off the GPU and for other errors', () {
      for (final message in [
        stream(activationDataType: null),
        stream(activationDataType: 1),
        stream(backend: 'cpu'),
        stream(backend: null),
        stream(error: 'RESOURCE_EXHAUSTED: context full'),
        stream(error: 'NOT_FOUND: Failed to invoke the compiled model'),
      ]) {
        expect(message, startsWith('Stream error: '));
        expect(message, isNot(contains('float32')));
        expect(message, isNot(contains(' (')), reason: 'no hint at all');
      }
    });
  });
}
