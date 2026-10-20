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
    ActivationDataType? rule({
      ActivationDataType? requested,
      PreferredBackend? preferredBackend = PreferredBackend.gpu,
      ModelType modelType = ModelType.functionGemma,
      bool? declaresKey = false,
    }) => gpuActivationDefault(
      requested: requested,
      preferredBackend: preferredBackend,
      modelType: modelType,
      declaresKey: declaresKey,
    );

    test('FunctionGemma without the key gets float32', () {
      expect(rule(), ActivationDataType.float32);
    });

    test('an explicit value wins, float16 included', () {
      expect(
        rule(requested: ActivationDataType.float16),
        ActivationDataType.float16,
      );
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

    test('other families without the key are left alone', () {
      for (final type in ModelType.values) {
        if (type == ModelType.functionGemma) continue;
        expect(rule(modelType: type), isNull, reason: type.name);
      }
    });

    // The gate the engine applies, over everything it depends on. A request
    // with no backend is the default order (GPU first) and must be eligible:
    // narrowing the CPU exclusion to `== gpu` breaks exactly that call.
    test('backend x family x declares: only the eligible cells choose', () {
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
            final expected =
                backend != PreferredBackend.cpu &&
                    family == ModelType.functionGemma &&
                    declares == false
                ? ActivationDataType.float32
                : null;
            expect(
              rule(
                preferredBackend: backend,
                modelType: family,
                declaresKey: declares,
              ),
              expected,
              reason: '${backend?.name} ${family.name} declares=$declares',
            );
          }
        }
      }
    });

    test('the header is read only when it can change the answer', () {
      bool matters({
        ActivationDataType? requested,
        PreferredBackend? backend,
        ModelType family = ModelType.functionGemma,
      }) => activationHeaderMatters(
        requested: requested,
        preferredBackend: backend,
        modelType: family,
      );
      expect(matters(), isTrue);
      expect(matters(backend: PreferredBackend.gpu), isTrue);
      expect(matters(backend: PreferredBackend.npu), isTrue);
      expect(matters(backend: PreferredBackend.cpu), isFalse);
      expect(matters(requested: ActivationDataType.float16), isFalse);
      expect(matters(family: ModelType.gemmaIt), isFalse);
      expect(matters(family: ModelType.gemma4), isFalse);
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
