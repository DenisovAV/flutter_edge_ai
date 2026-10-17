// `readLiteRtLmNpuTarget`: which NPU a `.litertlm` bundle was compiled for,
// from the `LiteRtStamp` LiteRT's AOT compiler writes into each compiled
// model — the only thing that tells a per-SoC EmbeddingGemma 2 bundle from the
// generic one (ModelInfo reports the same for both; measured on
// native-v0.18.0-e, see the reader's header).
//
// Synthetic containers (litertlm_container_fixture.dart) cover the rules; the
// real bundles are checked when their paths are given:
//   EG2_NPU_LITERTLM=<…_Qualcomm_SM8850.litertlm> EG2_NPU_SOC=SM8850 \
//   EG2_440M_LITERTLM=<generic 440m> flutter test test/litertlm_npu_target_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_npu_target.dart';
import 'package:flutter_test/flutter_test.dart';

import 'litertlm_container_fixture.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('npu_target_test_'));
  tearDown(() => root.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final path = '${root.path}/$name';
    File(path).writeAsBytesSync(bytes);
    return path;
  }

  const sm8850 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850');

  test('the generic bundle has no compiled section: null', () async {
    final path = write('eg2.litertlm', eg2Container(vision: true));
    expect(await readLiteRtLmNpuTarget(path), isNull);
  });

  test('a stamped text encoder is the NPU it names', () async {
    final path = write(
      'eg2_npu.litertlm',
      eg2Container(textStamp: ('Qualcomm', 'SM8850')),
    );
    final target = await readLiteRtLmNpuTarget(path);
    expect(target, sm8850);
    expect(target!.isQualcomm, isTrue);
    expect('$target', 'Qualcomm SM8850');
  });

  test("Google's Intel bundles, stamped IntelOpenVINO / PTL in each tower, "
      'are Intel, not Qualcomm', () async {
    final path = write(
      'eg2_ptl.litertlm',
      eg2Container(
        textStamp: ('IntelOpenVINO', 'PTL'),
        vision: true,
        visionStamp: ('IntelOpenVINO', 'PTL'),
      ),
    );
    final target = await readLiteRtLmNpuTarget(path);
    expect(
      target,
      const LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL'),
    );
    expect(target!.isIntel, isTrue);
    expect(target.isQualcomm, isFalse);
    expect('$target', 'IntelOpenVINO PTL');
    expect(sm8850.isIntel, isFalse);
    // Any case, as isQualcomm; a bare "Intel" is not LiteRT's OpenVINO stamp.
    expect(
      const LiteRtLmNpuTarget(vendor: 'INTELOPENVINO', soc: 'PTL').isIntel,
      isTrue,
    );
    expect(
      const LiteRtLmNpuTarget(vendor: 'Intel', soc: 'PTL').isIntel,
      isFalse,
    );
  });

  test(
    'a stamp in any compiled section counts, not only the text encoder',
    () async {
      final path = write(
        'eg2_vision_npu.litertlm',
        eg2Container(vision: true, visionStamp: ('Qualcomm', 'QCS8275')),
      );
      expect(
        await readLiteRtLmNpuTarget(path),
        const LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'QCS8275'),
      );
    },
  );

  test('two towers stamped alike are one target; differently, a '
      'FormatException', () async {
    final alike = write(
      'alike.litertlm',
      eg2Container(
        textStamp: ('Qualcomm', 'SM8850'),
        vision: true,
        visionStamp: ('Qualcomm', 'SM8850'),
      ),
    );
    expect(await readLiteRtLmNpuTarget(alike), sm8850);

    final mixed = write(
      'mixed.litertlm',
      eg2Container(
        textStamp: ('Qualcomm', 'SM8850'),
        vision: true,
        visionStamp: ('Qualcomm', 'SM8750'),
      ),
    );
    await expectLater(
      readLiteRtLmNpuTarget(mixed),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('SM8850'), contains('SM8750')),
        ),
      ),
    );
  });

  test(
    'a stamp kept outside the flatbuffer (Buffer.offset/size) is read',
    () async {
      final path = write(
        'appended.litertlm',
        eg2Container(textStamp: ('Google', 'Tensor_G5'), appendedStamp: true),
      );
      final target = await readLiteRtLmNpuTarget(path);
      expect(
        target,
        const LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
      );
      expect(target!.isQualcomm, isFalse);
      expect(target.isGoogleTensor, isTrue);
      expect(
        const LiteRtLmNpuTarget(
          vendor: 'GOOGLE',
          soc: 'Tensor_G6',
        ).isGoogleTensor,
        isTrue,
      );
    },
  );

  test('a stamp of a layout this reader does not know, or one naming no SoC, '
      'is an error — never "generic": only a compiled model has one', () async {
    for (final (name, stamp) in [
      ('long', Uint8List(375)..setAll(0, 'Qualcomm'.codeUnits)),
      ('empty', liteRtStamp('', '')),
    ]) {
      final path = write(
        '$name.litertlm',
        litertlmContainer([
          (
            type: sectionTfliteModel,
            modelType: 'tf_lite_text_encoder',
            bytes: tfliteModel({'LiteRtStamp': stamp}),
          ),
        ]),
      );
      await expectLater(
        readLiteRtLmNpuTarget(path),
        throwsFormatException,
        reason: name,
      );
    }
  });

  test('not a container, a truncated one, and a missing file are errors, '
      'never "generic"', () async {
    await expectLater(
      readLiteRtLmNpuTarget(write('x.litertlm', List.filled(64, 1))),
      throwsFormatException,
    );
    final whole = eg2Container(textStamp: ('Qualcomm', 'SM8850'));
    final truncated = write(
      'cut.litertlm',
      whole.sublist(0, whole.length ~/ 2),
    );
    await expectLater(readLiteRtLmNpuTarget(truncated), throwsFormatException);
    await expectLater(
      readLiteRtLmNpuTarget('${root.path}/absent.litertlm'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('an LLM bundle\'s header, extended (sparse) to where its last section '
      'ends, reads as no NPU target — what the device suite installs as an '
      'embedder to see the LLM refused', () async {
    // The header of a Gemma 3 1B bundle; its sections end at 584,413,712.
    final header = File(
      'test/ffi/fixtures/gemma3_1b_prefix.litertlm',
    ).readAsBytesSync();
    final cut = write('llm_header.litertlm', header);
    await expectLater(
      readLiteRtLmNpuTarget(cut),
      throwsA(isA<FormatException>()),
      reason: 'the header alone is a truncated container',
    );
    final file = File(cut);
    final raf = file.openSync(mode: FileMode.append);
    try {
      raf.truncateSync(584413712);
    } finally {
      raf.closeSync();
    }
    expect(await readLiteRtLmNpuTarget(cut), isNull);
  });

  group('parseLiteRtStamp', () {
    test('two NUL-padded 125-byte fields', () {
      expect(parseLiteRtStamp(liteRtStamp('Qualcomm', 'SM8850')), sm8850);
    });

    test('a buffer of another size, or an empty field, is not a stamp', () {
      expect(parseLiteRtStamp(Uint8List(249)), isNull);
      expect(parseLiteRtStamp(liteRtStamp('Qualcomm', '')), isNull);
      expect(parseLiteRtStamp(liteRtStamp('', 'SM8850')), isNull);
    });
  });

  group('the real bundles (opt-in)', () {
    const npu = String.fromEnvironment('EG2_NPU_LITERTLM');
    final npuPath = Platform.environment['EG2_NPU_LITERTLM'] ?? npu;
    final soc = Platform.environment['EG2_NPU_SOC'] ?? 'SM8850';
    final generic = Platform.environment['EG2_440M_LITERTLM'];

    test('a per-SoC bundle reads as Qualcomm <SoC>', () async {
      final watch = Stopwatch()..start();
      final target = await readLiteRtLmNpuTarget(npuPath);
      // ignore: avoid_print
      print('[eg2-npu] $npuPath → $target in ${watch.elapsedMilliseconds} ms');
      expect(target, LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: soc));
    }, skip: npuPath.isEmpty ? 'set EG2_NPU_LITERTLM' : false);

    test('the generic 440m reads as no NPU', () async {
      expect(await readLiteRtLmNpuTarget(generic!), isNull);
    }, skip: generic == null ? 'set EG2_440M_LITERTLM' : false);
  });
}
