import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../litertlm_container_fixture.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('bundle_info_'));
  tearDown(() => root.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final file = File('${root.path}/$name')..writeAsBytesSync(bytes);
    return file.path;
  }

  /// A real header fixture, extended (sparse) to the length its sections say,
  /// so it reads as a complete file. The section bytes are zeros, which the
  /// stamp reader reads as "not compiled".
  Future<LiteRtLmBundleInfo> completeHeader(String fixture) async {
    final header = File('test/ffi/fixtures/$fixture').readAsBytesSync();
    final path = write(fixture, header);
    final cut = await readLiteRtLmBundleInfo(path);
    final raf = File(path).openSync(mode: FileMode.append);
    try {
      raf.truncateSync(cut.expectedLength);
    } finally {
      raf.closeSync();
    }
    return readLiteRtLmBundleInfo(path);
  }

  group('real headers', () {
    test('the generic Gemma 4 E2B: declared CPU encoders, an MTP drafter, '
        'no NPU', () async {
      final info = await completeHeader('gemma4_e2b_header.litertlm');

      expect(
        (info.majorVersion, info.minorVersion, info.patchVersion),
        (1, 5, 0),
      );
      expect(info.systemMetadata['author'], 'The ODML Authors');
      expect(info.isComplete, isTrue);
      expect(info.sections.map((s) => s.dataType).take(3), [
        'LlmMetadataProto',
        'SP_Tokenizer',
        'TFLiteModel',
      ]);
      expect(info.audioEncoder!.backendConstraint, ['cpu']);
      expect(info.visionEncoder!.backendConstraint, isNull);
      expect(info.visionEncoder!.items['prefer_activation_type'], 'fp16');
      expect(info.textModel!.backendConstraint, isNull);
      expect(info.hasMtpDrafter, isTrue);
      expect(info.hasNpuAux, isFalse);
      expect(info.npuTarget, isNull);
      expect(info.isCompiledForNpu, isFalse);
    });

    test('the official SM8750 bundle: tf_lite_aux, nothing declared', () async {
      final info = await completeHeader(
        'gemma4_e2b_qualcomm_sm8750_header.litertlm',
      );

      expect(info.systemMetadata['Authors'], 'ODML team');
      expect(info.hasNpuAux, isTrue);
      expect(info.isCompiledForNpu, isTrue);
      expect(info.sections.where((s) => s.backendConstraint != null), isEmpty);
      expect(info.visionEncoder, isNotNull);
      expect(info.audioEncoder, isNotNull);
      expect(info.hasMtpDrafter, isFalse);
    });

    test('the official QCS8275 bundle: text on npu, encoders on cpu', () async {
      final info = await completeHeader(
        'gemma4_e2b_qualcomm_qcs8275_header.litertlm',
      );

      expect(info.textModel!.backendConstraint, ['npu']);
      expect(info.audioEncoder!.backendConstraint, ['cpu']);
      expect(info.sectionOf('tf_lite_vision_adapter')!.backendConstraint, [
        'cpu',
      ]);
      expect(info.visionEncoder!.backendConstraint, isNull);
      expect(info.hasNpuAux, isTrue);
    });

    test('the header alone is an incomplete file: sections listed, '
        'none stamped', () async {
      final path = write(
        'cut.litertlm',
        File(
          'test/ffi/fixtures/gemma4_e2b_google_tensor_g5_header.litertlm',
        ).readAsBytesSync(),
      );
      final info = await readLiteRtLmBundleInfo(path);

      expect(info.fileLength, 1736);
      expect(info.isComplete, isFalse);
      expect(info.expectedLength, greaterThan(3000000000));
      expect(info.hasMtpDrafter, isTrue);
      expect(info.sections.every((s) => s.npuTarget == null), isTrue);
    });
  });

  group('synthetic containers', () {
    Uint8List llm({
      (String, String)? textStamp,
      (String, String)? visionStamp,
      (String, String)? auxStamp,
      bool aux = false,
    }) {
      List<int> model((String, String)? stamp) => tfliteModel({
        if (stamp != null) 'LiteRtStamp': liteRtStamp(stamp.$1, stamp.$2),
      });
      return litertlmContainer(
        [
          (
            type: sectionTfliteModel,
            modelType: 'tf_lite_prefill_decode',
            bytes: model(textStamp),
          ),
          (
            type: sectionTfliteModel,
            modelType: 'TF_LITE_VISION_ENCODER',
            bytes: model(visionStamp),
          ),
          if (aux)
            (
              type: sectionTfliteModel,
              modelType: 'tf_lite_aux',
              bytes: model(auxStamp),
            ),
          (type: sectionSpTokenizer, modelType: null, bytes: [1, 2, 3]),
        ],
        items: {
          0: {'Backend_Constraint': 'NPU, gpu', 'batch': 4},
          1: {'quantized': true},
        },
        system: {'model_name': 'test', 'layers': 26, 'tuned': false},
      );
    }

    test('typed items, keys read case-insensitively, model types '
        'lowercased', () async {
      final info = await readLiteRtLmBundleInfo(write('a.litertlm', llm()));

      expect(info.systemMetadata, {
        'model_name': 'test',
        'layers': 26,
        'tuned': false,
      });
      expect(info.textModel!.backendConstraint, ['npu', 'gpu']);
      expect(info.textModel!.items['batch'], 4);
      expect(info.visionEncoder!.modelType, 'tf_lite_vision_encoder');
      expect(info.visionEncoder!.items['quantized'], isTrue);
      expect(info.sections.last.dataType, 'SP_Tokenizer');
      expect(info.sections.last.modelType, isNull);
    });

    test('each compiled section carries the NPU it targets', () async {
      final info = await readLiteRtLmBundleInfo(
        write('b.litertlm', llm(textStamp: ('Qualcomm', 'SM8750'), aux: true)),
      );

      expect(
        info.textModel!.npuTarget,
        const LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750'),
      );
      expect(info.visionEncoder!.npuTarget, isNull);
      expect(info.npuTarget!.soc, 'SM8750');
      expect(info.isCompiledForNpu, isTrue);
      expect(info.sections.last.npuTarget, isNull);
    });

    test('a stamped text model without a tf_lite_aux section marks the '
        'bundle compiled for an NPU', () async {
      final info = await readLiteRtLmBundleInfo(
        write('c.litertlm', llm(textStamp: ('Google', 'Tensor_G5'))),
      );

      expect(info.hasNpuAux, isFalse);
      expect(info.isCompiledForNpu, isTrue);
    });

    test('an encoder compiled for an NPU alone does not make the text model '
        'NPU-only', () async {
      final info = await readLiteRtLmBundleInfo(
        write('c2.litertlm', llm(visionStamp: ('Qualcomm', 'SM8750'))),
      );

      expect(info.visionEncoder!.npuTarget!.soc, 'SM8750');
      expect(info.npuTarget!.soc, 'SM8750');
      expect(info.hasNpuAux, isFalse);
      expect(info.isCompiledForNpu, isFalse);
    });

    test('only TFLiteModel sections are models: a TFLiteWeights section '
        'listed first with the same model_type does not hide the '
        'encoder', () async {
      final bundle = litertlmContainer(
        [
          (
            type: sectionTfliteWeights,
            modelType: 'tf_lite_vision_encoder',
            bytes: List.filled(32, 9),
          ),
          (
            type: sectionTfliteModel,
            modelType: 'tf_lite_prefill_decode',
            bytes: tfliteModel({}),
          ),
          (
            type: sectionTfliteModel,
            modelType: 'tf_lite_vision_encoder',
            bytes: tfliteModel({
              'LiteRtStamp': liteRtStamp('Qualcomm', 'SM8750'),
            }),
          ),
        ],
        items: {
          0: {'backend_constraint': 'cpu'},
          2: {'backend_constraint': 'npu'},
        },
      );
      final info = await readLiteRtLmBundleInfo(write('w.litertlm', bundle));

      expect(info.visionEncoder!.dataType, 'TFLiteModel');
      expect(info.visionEncoder!.backendConstraint, ['npu']);
      expect(info.visionEncoder!.npuTarget!.soc, 'SM8750');
    });

    test('a TFLiteModel section without a model_type is the text model, as '
        'LiteRT-LM reads it; a tokenizer without one is not', () async {
      final bundle = litertlmContainer(
        [
          (type: sectionSpTokenizer, modelType: null, bytes: [1, 2, 3]),
          (type: sectionTfliteModel, modelType: null, bytes: tfliteModel({})),
          (
            type: sectionTfliteModel,
            modelType: 'tf_lite_vision_encoder',
            bytes: tfliteModel({}),
          ),
        ],
        items: {
          1: {'backend_constraint': 'cpu'},
        },
      );
      final info = await readLiteRtLmBundleInfo(write('t.litertlm', bundle));

      expect(info.textModel, same(info.sections[1]));
      expect(info.textModel!.backendConstraint, ['cpu']);
    });

    test('sections stamped for two SoCs are malformed', () async {
      await expectLater(
        readLiteRtLmBundleInfo(
          write(
            'd.litertlm',
            llm(
              textStamp: ('Qualcomm', 'SM8750'),
              visionStamp: ('Qualcomm', 'SM8650'),
            ),
          ),
        ),
        throwsA(
          isA<LiteRtLmBundleException>().having(
            (e) => e.problem,
            'problem',
            LiteRtLmBundleProblem.malformed,
          ),
        ),
      );
    });

    test('a stamp of a layout this version cannot read is malformed, never '
        '"not compiled"', () async {
      final bundle = litertlmContainer([
        (
          type: sectionTfliteModel,
          modelType: 'tf_lite_prefill_decode',
          bytes: tfliteModel({'LiteRtStamp': List.filled(249, 65)}),
        ),
      ]);
      await expectLater(
        readLiteRtLmBundleInfo(write('e.litertlm', bundle)),
        throwsA(
          isA<LiteRtLmBundleException>().having(
            (e) => e.problem,
            'problem',
            LiteRtLmBundleProblem.malformed,
          ),
        ),
      );
    });
  });

  group('files that are not complete containers', () {
    Matcher problem(LiteRtLmBundleProblem p) => throwsA(
      isA<LiteRtLmBundleException>().having((e) => e.problem, 'problem', p),
    );

    test('no magic, a short file, a .task zip', () async {
      await expectLater(
        readLiteRtLmBundleInfo(write('x', List.filled(64, 1))),
        problem(LiteRtLmBundleProblem.notLitertlm),
      );
      await expectLater(
        readLiteRtLmBundleInfo(write('y', [1, 2, 3])),
        problem(LiteRtLmBundleProblem.notLitertlm),
      );
      await expectLater(
        readLiteRtLmBundleInfo(
          write('z.task', [0x50, 0x4b, 3, 4, ...List.filled(60, 0)]),
        ),
        problem(LiteRtLmBundleProblem.notLitertlm),
      );
    });

    test('another major version', () async {
      final bundle = litertlmContainer([
        (type: sectionSpTokenizer, modelType: null, bytes: [1]),
      ]);
      ByteData.sublistView(bundle).setUint32(8, 2, Endian.little);
      await expectLater(
        readLiteRtLmBundleInfo(write('v2.litertlm', bundle)),
        problem(LiteRtLmBundleProblem.unsupportedVersion),
      );
    });

    test('a file that ends inside its header is incomplete', () async {
      final bundle = litertlmContainer([
        (type: sectionSpTokenizer, modelType: null, bytes: [1]),
      ]);
      await expectLater(
        readLiteRtLmBundleInfo(write('cut.litertlm', bundle.sublist(0, 40))),
        problem(LiteRtLmBundleProblem.incomplete),
      );
    });

    test('a file that ends inside its sections reads, as incomplete', () async {
      final bundle = litertlmContainer([
        (type: sectionSpTokenizer, modelType: null, bytes: List.filled(64, 1)),
      ]);
      final info = await readLiteRtLmBundleInfo(
        write('short.litertlm', bundle.sublist(0, bundle.length - 8)),
      );
      expect(info.isComplete, isFalse);
      expect(info.expectedLength - info.fileLength, greaterThan(0));
    });

    test('a missing file is a FileSystemException', () async {
      await expectLater(
        readLiteRtLmBundleInfo('${root.path}/absent.litertlm'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('real bundles (opt-in)', () {
    // Local copies, never committed: LITERTLM_NPU_BUNDLE an NPU-compiled
    // Gemma 4 (e.g. Google's all-NPU SM8750 build), LITERTLM_NPU_SOC its SoC.
    final npu = Platform.environment['LITERTLM_NPU_BUNDLE'];
    final soc = Platform.environment['LITERTLM_NPU_SOC'];

    test('reads every compiled section of an NPU bundle', () async {
      final watch = Stopwatch()..start();
      final info = await readLiteRtLmBundleInfo(npu!);
      // ignore: avoid_print
      print('[bundle-info] $info in ${watch.elapsedMilliseconds} ms');
      for (final section in info.sections) {
        // ignore: avoid_print
        print('[bundle-info]   $section ${section.items}');
      }
      expect(info.isComplete, isTrue);
      expect(info.npuTarget?.soc, soc);
    }, skip: npu == null ? 'set LITERTLM_NPU_BUNDLE' : false);
  });
}
