// Golden test for `Qwen3Prompt.build` — the talker prompt-embedding
// assembly (role text, control/x-vector rows, streamed text conditioning)
// for the Qwen3-TTS pipeline.
//
// Like `qwen3_tables_test.dart`, this is an artifact-heavy test: it needs
// the real Qwen3-TTS host tables (~722 MB) via `Qwen3Tables` to compute
// `embedText`/`codecEmbRow` results, which are not committed to the repo.
// The golden reference (`test/golden/qwen3/prompt.npz`, `ids.json`,
// `voices/demo_speaker.npy`) IS committed (Task 0). When the tables are
// absent (e.g. CI without the artifact fetched) the test skips gracefully;
// when present (local device runs) it asserts the golden.
@Tags(['qwen3-artifacts'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/qwen3/npy_reader.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_prompt.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_tables.dart';
import 'package:flutter_test/flutter_test.dart';

/// Default location of the Qwen3-TTS model snapshot's `tables/` directory —
/// mirrors `qwen3_tables_test.dart`'s `_defaultTablesDir`. Override with the
/// `QWEN3_MODEL_DIR` environment variable.
String _defaultTablesDir() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.cache/huggingface/hub/'
      'models--litert-community--Qwen3-TTS-12Hz-0.6B-Base/snapshots/'
      '66855540b3b34679f06c3ff07859603fc9514c66/tables';
}

String _tablesDir() => Platform.environment['QWEN3_MODEL_DIR'] != null
    ? '${Platform.environment['QWEN3_MODEL_DIR']}/tables'
    : _defaultTablesDir();

double _maxAbsDiff(Float32List got, Float32List ref) {
  var maxDiff = 0.0;
  for (var i = 0; i < got.length; i++) {
    final diff = (got[i] - ref[i]).abs();
    if (diff > maxDiff) maxDiff = diff;
  }
  return maxDiff;
}

void _expectClose(
  Float32List got,
  Float32List ref, {
  required double tol,
  required String label,
}) {
  expect(
    got.length,
    ref.length,
    reason: '$label: length mismatch: got ${got.length}, ref ${ref.length}',
  );
  final maxDiff = _maxAbsDiff(got, ref);
  expect(
    maxDiff,
    lessThanOrEqualTo(tol),
    reason: '$label: max abs diff $maxDiff exceeds tolerance $tol',
  );
}

void main() {
  final tablesDir = _tablesDir();

  test('Qwen3Prompt.build matches prompt.npz golden within 2e-3 '
      '(prefill, trailing, tts_pad)', () async {
    if (!Directory(tablesDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model tables not found at $tablesDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final tables = await Qwen3Tables.load(
      codecEmbPath: '$tablesDir/codec_embedding_fp32.npy',
      mtpEmbPath: '$tablesDir/mtp_embeddings_fp16.npy',
      textEmbPath: '$tablesDir/text_embedding_fp16.npy',
      projectionNpzPath: '$tablesDir/text_projection_fp32.npz',
    );
    try {
      final idsJson =
          jsonDecode(File('test/golden/qwen3/ids.json').readAsStringSync())
              as Map<String, dynamic>;
      final ids = (idsJson['ids'] as List).cast<int>();

      final speaker = readNpyF32('test/golden/qwen3/voices/demo_speaker.npy');
      expect(speaker.length, 1024);

      final golden = readNpzF32('test/golden/qwen3/prompt.npz');
      final goldenPrefill = golden['prefill']!;
      final goldenTrailing = golden['trailing']!;
      final goldenTtsPad = golden['tts_pad']!;

      final result = Qwen3Prompt.build(
        ids: ids,
        speaker: speaker,
        language: 'english',
        tables: tables,
      );

      // english control -> codec_pre = 4(control) + 1(speaker) + 2(pad,bos)
      // = 7 rows -> promptLen = 3(role) + 6(body) + 1(first_text) = 10.
      expect(result.promptLen, 10);
      expect(result.prefill.length, result.promptLen * 1024);
      _expectClose(result.prefill, goldenPrefill, tol: 2e-3, label: 'prefill');

      expect(result.trailing.length, goldenTrailing.length ~/ 1024);
      final flatTrailing = Float32List(result.trailing.length * 1024);
      for (var i = 0; i < result.trailing.length; i++) {
        expect(result.trailing[i].length, 1024);
        flatTrailing.setRange(i * 1024, (i + 1) * 1024, result.trailing[i]);
      }
      _expectClose(flatTrailing, goldenTrailing, tol: 2e-3, label: 'trailing');

      expect(result.ttsPad.length, 1024);
      _expectClose(result.ttsPad, goldenTtsPad, tol: 2e-3, label: 'tts_pad');
    } finally {
      tables.dispose();
    }
  });

  test('Qwen3Prompt.build rejects an unsupported language', () async {
    if (!Directory(tablesDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model tables not found at $tablesDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final tables = await Qwen3Tables.load(
      codecEmbPath: '$tablesDir/codec_embedding_fp32.npy',
      mtpEmbPath: '$tablesDir/mtp_embeddings_fp16.npy',
      textEmbPath: '$tablesDir/text_embedding_fp16.npy',
      projectionNpzPath: '$tablesDir/text_projection_fp32.npz',
    );
    try {
      final idsJson =
          jsonDecode(File('test/golden/qwen3/ids.json').readAsStringSync())
              as Map<String, dynamic>;
      final ids = (idsJson['ids'] as List).cast<int>();
      final speaker = readNpyF32('test/golden/qwen3/voices/demo_speaker.npy');

      expect(
        () => Qwen3Prompt.build(
          ids: ids,
          speaker: speaker,
          language: 'klingon',
          tables: tables,
        ),
        throwsArgumentError,
      );
    } finally {
      tables.dispose();
    }
  });
}
