import 'dart:io';
import 'dart:typed_data';

import 'package:litertlm_dart/internal_io.dart';
import 'package:test/test.dart';

/// Real bundle headers, see fixtures/README.md. Only FunctionGemma and Gemma 4
/// are the ones whose answer matters; the other two are bundles the rule must
/// leave alone whichever way the key reads.
const _fixtures = 'test/ffi/fixtures';

Uint8List _header(String name) {
  final bytes = File('$_fixtures/$name').readAsBytesSync();
  final end = ByteData.sublistView(bytes).getUint64(24, Endian.little);
  return Uint8List.sublistView(bytes, 32, end);
}

/// A serialized `LlmMetadata` whose `llm_model_type` (field 6) is the oneof
/// case [field]: an empty message under it, as litert-torch writes the
/// families that carry no options.
Uint8List _metadataOfType(int field) => Uint8List.fromList([
  0x32, 2, // field 6, length-delimited, 2 bytes
  (field << 3) | 2, 0, // the oneof case, length-delimited, empty
]);

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

  group('llmMetadataMaxNumTokens (LlmMetadata.max_num_tokens)', () {
    Uint8List declaring(List<int> varint) =>
        Uint8List.fromList([0x28, ...varint, ..._metadataOfType(8)]);

    test('the declared value; none, 0 or a negative one is null', () {
      expect(llmMetadataMaxNumTokens(declaring([0x80, 0x20])), 4096);
      expect(llmMetadataMaxNumTokens(declaring([0x80, 0x80, 0x02])), 32768);
      expect(llmMetadataMaxNumTokens(_metadataOfType(8)), isNull);
      expect(llmMetadataMaxNumTokens(declaring([0])), isNull);
      expect(
        llmMetadataMaxNumTokens(
          declaring([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1]),
        ),
        isNull,
        reason: 'int32 -1',
      );
    });

    test('a truncated proto is a FormatException', () {
      expect(
        () => llmMetadataMaxNumTokens(Uint8List.fromList([0x28, 0x80])),
        throwsFormatException,
      );
    });

    test('real bundles: Gemma 3 1B declares none, Qwen3 0.6B 4096', () async {
      expect(
        await readLlmMaxNumTokens('$_fixtures/gemma3_1b_prefix.litertlm'),
        isNull,
      );
      expect(
        await readLlmMaxNumTokens('$_fixtures/qwen3_0_6b_prefix.litertlm'),
        4096,
      );
    });
  });

  group('llmModelFamilyFrom (LlmMetadata.llm_model_type)', () {
    test('gemma4 = 8 and function_gemma = 3 are the families with rules', () {
      expect(llmModelFamilyFrom(_metadataOfType(8)), LlmModelFamily.gemma4);
      expect(
        llmModelFamilyFrom(_metadataOfType(3)),
        LlmModelFamily.functionGemma,
      );
    });

    test('any other family is other, none is null', () {
      for (final field in [1, 2, 4, 5, 7, 9, 11, 12, 13]) {
        expect(
          llmModelFamilyFrom(_metadataOfType(field)),
          LlmModelFamily.other,
          reason: 'case $field',
        );
      }
      expect(llmModelFamilyFrom(Uint8List(0)), isNull);
    });

    test('a truncated proto is a FormatException', () {
      expect(
        () => llmModelFamilyFrom(Uint8List.fromList([0x32, 9, 0x42])),
        throwsFormatException,
      );
    });

    test(
      'real bundles: Gemma 3 1B names none, Qwen3 0.6B dynamic another',
      () async {
        expect(
          await readLlmModelFamily('$_fixtures/gemma3_1b_prefix.litertlm'),
          isNull,
        );
        expect(
          await readLlmModelFamily(
            '$_fixtures/qwen3_0_6b_dynamic_prefix.litertlm',
          ),
          LlmModelFamily.other,
        );
      },
    );
  });

  group('gpuActivationFor', () {
    test('Gemma 4: 2,048 keeps the default, 2,049 gets float32 (#4001)', () {
      expect(
        gpuActivationFor(
          family: LlmModelFamily.gemma4,
          declaresActivation: true,
          maxNumTokens: 2048,
          android: false,
        ),
        (type: null, reason: null),
      );
      expect(
        gpuActivationFor(
          family: LlmModelFamily.gemma4,
          declaresActivation: true,
          maxNumTokens: 2049,
          android: false,
        ),
        (
          type: ActivationDataType.float32,
          reason: GpuActivationReason.gemma4LongContext,
        ),
      );
    });

    test('on Android, Gemma 4 keeps float16 above 2,048 and says why; '
        'FunctionGemma without the key still gets float32', () {
      expect(
        gpuActivationFor(
          family: LlmModelFamily.gemma4,
          declaresActivation: true,
          maxNumTokens: 4096,
          android: true,
        ),
        (type: null, reason: GpuActivationReason.gemma4LongContextAndroid),
      );
      expect(
        gpuActivationFor(
          family: LlmModelFamily.gemma4,
          declaresActivation: true,
          maxNumTokens: 2048,
          android: true,
        ),
        (type: null, reason: null),
      );
      expect(
        gpuActivationFor(
          family: LlmModelFamily.functionGemma,
          declaresActivation: false,
          maxNumTokens: 1024,
          android: true,
        ),
        (
          type: ActivationDataType.float32,
          reason: GpuActivationReason.functionGemmaWithoutKey,
        ),
      );
    });

    test('FunctionGemma without the key gets float32 at any context', () {
      for (final tokens in [1024, 4096]) {
        expect(
          gpuActivationFor(
            family: LlmModelFamily.functionGemma,
            declaresActivation: false,
            maxNumTokens: tokens,
            android: false,
          ),
          (
            type: ActivationDataType.float32,
            reason: GpuActivationReason.functionGemmaWithoutKey,
          ),
        );
      }
    });

    test(
      'a FunctionGemma that declares the key, or is unread, is left alone',
      () {
        for (final declares in [true, null]) {
          expect(
            gpuActivationFor(
              family: LlmModelFamily.functionGemma,
              declaresActivation: declares,
              maxNumTokens: 1024,
              android: false,
            ).type,
            isNull,
          );
        }
      },
    );

    test('other families and unnamed bundles are left alone', () {
      for (final family in [LlmModelFamily.other, null]) {
        for (final declares in [true, false, null]) {
          expect(
            gpuActivationFor(
              family: family,
              declaresActivation: declares,
              maxNumTokens: 8192,
              android: false,
            ).type,
            isNull,
            reason: '$family, declares $declares',
          );
        }
      }
    });
  });
}
