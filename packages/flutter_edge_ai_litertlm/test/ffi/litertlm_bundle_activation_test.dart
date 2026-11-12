import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine.dart';
import 'package:flutter_edge_ai_litertlm/src/litertlm_bundle_activation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real bundle headers, see fixtures/README.md. Only FunctionGemma and Gemma 4
/// are the ones whose answer matters; the other two are bundles the rule must
/// leave alone whichever way the key reads.
const _fixtures = 'test/ffi/fixtures';

Uint8List _header(String name) {
  final bytes = File('$_fixtures/$name').readAsBytesSync();
  final end = ByteData.sublistView(bytes).getUint64(24, Endian.little);
  return Uint8List.sublistView(bytes, 32, end);
}

RuntimeConfig _config({
  ActivationDataType? activationDataType,
  PreferredBackend? preferredBackend,
}) => RuntimeConfig(
  maxTokens: 1024,
  modelPath: '/tmp/model.litertlm',
  preferredBackend: preferredBackend,
  activationDataType: activationDataType,
);

void main() {
  group('litertlmDeclaresActivationType', () {
    test('a FunctionGemma bundle converted without the key declares none', () {
      expect(
        litertlmDeclaresActivationType(
          _header('functiongemma_270m_header.litertlm'),
        ),
        isFalse,
      );
    });

    test('a Gemma 4 bundle declares it, on its prefill/decode section', () {
      expect(
        litertlmDeclaresActivationType(_header('gemma4_e2b_header.litertlm')),
        isTrue,
      );
    });

    test('Gemma 3 1B and Qwen3 0.6B declare none', () {
      for (final name in [
        'gemma3_1b_prefix.litertlm',
        'qwen3_0_6b_prefix.litertlm',
      ]) {
        expect(
          litertlmDeclaresActivationType(_header(name)),
          isFalse,
          reason: name,
        );
      }
    });

    test('a truncated header is a FormatException, not a guess', () {
      final header = _header('gemma4_e2b_header.litertlm');
      expect(
        () => litertlmDeclaresActivationType(
          Uint8List.sublistView(header, 0, header.length ~/ 2),
        ),
        throwsFormatException,
      );
    });
  });

  group('tryReadBundleActivationDeclaration', () {
    test('reads the same answers from a file path', () async {
      final functionGemma = await tryReadBundleActivationDeclaration(
        '$_fixtures/functiongemma_270m_header.litertlm',
      );
      expect(functionGemma.declaresKey, isFalse);
      expect(functionGemma.error, isNull);
      final gemma4 = await tryReadBundleActivationDeclaration(
        '$_fixtures/gemma4_e2b_header.litertlm',
      );
      expect(gemma4.declaresKey, isTrue);
      expect(gemma4.error, isNull);
    });

    test('a missing file is unknown, and says why', () async {
      final read = await tryReadBundleActivationDeclaration(
        '$_fixtures/no_such.litertlm',
      );
      expect(read.declaresKey, isNull);
      expect(read.error, startsWith('FileSystemException'));
    });

    test('a file that is not a bundle is unknown, and says why', () async {
      final notBundle = File('${Directory.systemTemp.path}/not_a_bundle.bin')
        ..writeAsBytesSync(List.filled(64, 7));
      addTearDown(notBundle.deleteSync);
      final read = await tryReadBundleActivationDeclaration(notBundle.path);
      expect(read.declaresKey, isNull);
      expect(read.error, startsWith('FormatException'));
    });
  });

  group('gpuActivationDefault', () {
    ({ActivationDataType? type, GpuActivationReason? reason}) choose({
      ActivationDataType? requested,
      PreferredBackend? preferredBackend = PreferredBackend.gpu,
      ModelType modelType = ModelType.functionGemma,
      bool? declaresKey = false,
      int maxTokens = 1024,
    }) => gpuActivationDefault(
      requested: requested,
      preferredBackend: preferredBackend,
      modelType: modelType,
      declaresKey: declaresKey,
      maxTokens: maxTokens,
    );

    ActivationDataType? rule({
      ActivationDataType? requested,
      PreferredBackend? preferredBackend = PreferredBackend.gpu,
      ModelType modelType = ModelType.functionGemma,
      bool? declaresKey = false,
      int maxTokens = 1024,
    }) => choose(
      requested: requested,
      preferredBackend: preferredBackend,
      modelType: modelType,
      declaresKey: declaresKey,
      maxTokens: maxTokens,
    ).type;

    test('FunctionGemma without the key gets float32', () {
      expect(choose(), (
        type: ActivationDataType.float32,
        reason: GpuActivationReason.functionGemmaWithoutKey,
      ));
    });

    test('FunctionGemma does not depend on the context', () {
      for (final maxTokens in [1024, 2048, 2049, 32768]) {
        expect(
          rule(maxTokens: maxTokens),
          ActivationDataType.float32,
          reason: '$maxTokens',
        );
        expect(
          rule(maxTokens: maxTokens, declaresKey: true),
          isNull,
          reason: '$maxTokens',
        );
      }
    });

    test('an explicit value wins, float16 included', () {
      expect(choose(requested: ActivationDataType.float16), (
        type: ActivationDataType.float16,
        reason: null,
      ));
      expect(
        rule(requested: ActivationDataType.float32, declaresKey: true),
        ActivationDataType.float32,
      );
    });

    test('a bundle that declares the key is left alone', () {
      expect(rule(declaresKey: true), isNull);
    });

    test('an unreadable header is not guessed about', () {
      expect(rule(declaresKey: null), isNull);
    });

    test('other families without the key are left alone, at any context', () {
      for (final type in ModelType.values) {
        if (type == ModelType.functionGemma) continue;
        for (final maxTokens in [1024, 2048]) {
          expect(
            rule(modelType: type, maxTokens: maxTokens),
            isNull,
            reason: '${type.name} $maxTokens',
          );
        }
        if (type == ModelType.gemma4) continue;
        expect(
          rule(modelType: type, maxTokens: 8192),
          isNull,
          reason: '${type.name} 8192',
        );
      }
    });

    group('Gemma 4 (#827)', () {
      test('a context of 2,048 keeps the default; 2,049 gets float32', () {
        for (final declares in <bool?>[true, false, null]) {
          expect(
            rule(
              modelType: ModelType.gemma4,
              declaresKey: declares,
              maxTokens: 2048,
            ),
            isNull,
            reason: 'declares=$declares',
          );
          expect(
            choose(
              modelType: ModelType.gemma4,
              declaresKey: declares,
              maxTokens: 2049,
            ),
            (
              type: ActivationDataType.float32,
              reason: GpuActivationReason.gemma4LongContext,
            ),
            reason: 'declares=$declares',
          );
        }
        expect(
          rule(modelType: ModelType.gemma4, maxTokens: 4096),
          ActivationDataType.float32,
        );
      });

      test('an explicit float16 wins over a long context', () {
        expect(
          choose(
            modelType: ModelType.gemma4,
            maxTokens: 8192,
            requested: ActivationDataType.float16,
          ),
          (type: ActivationDataType.float16, reason: null),
        );
      });

      test('the CPU is left alone at any context', () {
        expect(
          rule(
            modelType: ModelType.gemma4,
            maxTokens: 8192,
            preferredBackend: PreferredBackend.cpu,
          ),
          isNull,
        );
      });

      test('the default order and an NPU request reach it (their GPU '
          'attempts)', () {
        for (final backend in <PreferredBackend?>[null, PreferredBackend.npu]) {
          expect(
            rule(
              modelType: ModelType.gemma4,
              maxTokens: 4096,
              preferredBackend: backend,
            ),
            ActivationDataType.float32,
            reason: '${backend?.name}',
          );
        }
      });
    });

    // The gate the engine applies, over everything it depends on. A request
    // with no backend is the default order (GPU first) and must be eligible:
    // narrowing the CPU exclusion to `== gpu` breaks exactly that call.
    test('backend x family x declares x context: only the eligible cells '
        'choose', () {
      const backends = <PreferredBackend?>[
        null,
        PreferredBackend.gpu,
        PreferredBackend.npu,
        PreferredBackend.cpu,
      ];
      const families = [
        ModelType.functionGemma,
        ModelType.gemmaIt,
        ModelType.gemma4,
      ];
      for (final backend in backends) {
        for (final family in families) {
          for (final declares in <bool?>[true, false, null]) {
            for (final maxTokens in [1024, 2048, 2049, 4096]) {
              final gpuReachable = backend != PreferredBackend.cpu;
              final functionGemma =
                  family == ModelType.functionGemma && declares == false;
              final gemma4Long = family == ModelType.gemma4 && maxTokens > 2048;
              final expected = gpuReachable && (functionGemma || gemma4Long)
                  ? ActivationDataType.float32
                  : null;
              expect(
                rule(
                  preferredBackend: backend,
                  modelType: family,
                  declaresKey: declares,
                  maxTokens: maxTokens,
                ),
                expected,
                reason:
                    '${backend?.name} ${family.name} declares=$declares '
                    'maxTokens=$maxTokens',
              );
            }
          }
        }
      }
    });

    test('the header is read only when it can change the answer', () {
      bool matters({
        ActivationDataType? requested,
        PreferredBackend? backend,
        ModelType family = ModelType.functionGemma,
        int maxTokens = 1024,
      }) => activationHeaderMatters(
        requested: requested,
        preferredBackend: backend,
        modelType: family,
        maxTokens: maxTokens,
      );
      expect(matters(), isTrue);
      expect(matters(maxTokens: 4096), isTrue);
      expect(matters(backend: PreferredBackend.gpu), isTrue);
      expect(matters(backend: PreferredBackend.npu), isTrue);
      expect(matters(backend: PreferredBackend.cpu), isFalse);
      expect(matters(requested: ActivationDataType.float16), isFalse);
      expect(matters(family: ModelType.gemmaIt), isFalse);
      // Gemma 4 is decided by the context alone, either way.
      expect(matters(family: ModelType.gemma4), isFalse);
      expect(matters(family: ModelType.gemma4, maxTokens: 4096), isFalse);
    });
  });

  group('encoderInitArgs with the engine default', () {
    test('a GPU attempt takes it', () {
      final args = encoderInitArgs(
        _config(),
        PreferredBackend.gpu,
        gpuDefaultActivation: ActivationDataType.float32,
      );
      expect(args.activationDataType, 0);
    });

    test('a CPU or NPU attempt does not', () {
      for (final backend in [PreferredBackend.cpu, PreferredBackend.npu]) {
        final args = encoderInitArgs(
          _config(),
          backend,
          gpuDefaultActivation: ActivationDataType.float32,
        );
        expect(args.activationDataType, isNull, reason: backend.name);
      }
    });

    test('the caller\'s value wins over it on every backend', () {
      for (final backend in PreferredBackend.values) {
        final args = encoderInitArgs(
          _config(activationDataType: ActivationDataType.float16),
          backend,
          gpuDefaultActivation: ActivationDataType.float32,
        );
        expect(args.activationDataType, 1, reason: backend.name);
      }
    });

    test('with no default and no caller value nothing is sent', () {
      expect(
        encoderInitArgs(_config(), PreferredBackend.gpu).activationDataType,
        isNull,
      );
    });
  });
}
