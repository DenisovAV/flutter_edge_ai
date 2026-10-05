// Golden test for `Qwen3Tables` — the host embedding tables + text
// projection MLP that turn Qwen3-TTS token ids into 1024-d talker-space
// embeddings.
//
// This is the first artifact-heavy test in the Qwen3-TTS port: the real
// model tables (~722 MB — codec_embedding_fp32.npy, mtp_embeddings_fp16.npy,
// text_embedding_fp16.npy, text_projection_fp32.npz) are NOT committed to
// the repo. They live in the local HuggingFace cache (see [_defaultTablesDir]
// below) or wherever `QWEN3_MODEL_DIR` points. When the tables are absent
// (e.g. in CI without the artifact fetched) the test skips gracefully so the
// suite stays green; when present (as they are for local device runs) it
// asserts the golden.
@Tags(['qwen3-artifacts'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/qwen3/npy_reader.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_tables.dart';
import 'package:flutter_test/flutter_test.dart';

/// Default location of the Qwen3-TTS model snapshot's `tables/` directory —
/// the local HuggingFace cache path for
/// `litert-community/Qwen3-TTS-12Hz-0.6B-Base`. Override with the
/// `QWEN3_MODEL_DIR` environment variable (pointing at a snapshot dir that
/// contains a `tables/` subdirectory) to run against a different snapshot.
String _defaultTablesDir() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.cache/huggingface/hub/'
      'models--litert-community--Qwen3-TTS-12Hz-0.6B-Base/snapshots/'
      '66855540b3b34679f06c3ff07859603fc9514c66/tables';
}

String _tablesDir() => Platform.environment['QWEN3_MODEL_DIR'] != null
    ? '${Platform.environment['QWEN3_MODEL_DIR']}/tables'
    : _defaultTablesDir();

void _expectClose(Float32List got, Float32List ref, {required double tol}) {
  expect(
    got.length,
    ref.length,
    reason: 'length mismatch: got ${got.length}, ref ${ref.length}',
  );
  var maxDiff = 0.0;
  var maxDiffIndex = -1;
  for (var i = 0; i < got.length; i++) {
    final diff = (got[i] - ref[i]).abs();
    if (diff > maxDiff) {
      maxDiff = diff;
      maxDiffIndex = i;
    }
  }
  expect(
    maxDiff,
    lessThanOrEqualTo(tol),
    reason:
        'max abs diff $maxDiff at index $maxDiffIndex exceeds tolerance '
        '$tol (got=${got[maxDiffIndex]}, ref=${ref[maxDiffIndex]})',
  );
}

void main() {
  final tablesDir = _tablesDir();

  test(
    'embedText matches reference within 2e-3 (fp16 table up-cast)',
    () async {
      if (!Directory(tablesDir).existsSync()) {
        markTestSkipped(
          'Qwen3-TTS model tables not found at $tablesDir — set '
          'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
        );
        return;
      }

      final t = await Qwen3Tables.load(
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

        final got = t.embedText(ids);
        final ref = readNpyF32('test/golden/qwen3/embed_text.npy');

        expect(got.length, ids.length * 1024);
        _expectClose(got, ref, tol: 2e-3);
      } finally {
        t.dispose();
      }
    },
  );

  test('codecEmbRow / mtpEmbRow return 1024-d rows without OOB', () async {
    if (!Directory(tablesDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model tables not found at $tablesDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final t = await Qwen3Tables.load(
      codecEmbPath: '$tablesDir/codec_embedding_fp32.npy',
      mtpEmbPath: '$tablesDir/mtp_embeddings_fp16.npy',
      textEmbPath: '$tablesDir/text_embedding_fp16.npy',
      projectionNpzPath: '$tablesDir/text_projection_fp32.npz',
    );
    try {
      final codecRow = t.codecEmbRow(0);
      expect(codecRow.length, 1024);
      expect(codecRow.every((v) => v.isFinite), isTrue);

      final lastCodecRow = t.codecEmbRow(3071);
      expect(lastCodecRow.length, 1024);

      final mtpRow = t.mtpEmbRow(0, 0);
      expect(mtpRow.length, 1024);
      expect(mtpRow.every((v) => v.isFinite), isTrue);

      final lastMtpRow = t.mtpEmbRow(14, 2047);
      expect(lastMtpRow.length, 1024);
    } finally {
      t.dispose();
    }
  });

  test('projectText SiLU MLP shape: [n*2048] -> [n*1024]', () async {
    if (!Directory(tablesDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model tables not found at $tablesDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final t = await Qwen3Tables.load(
      codecEmbPath: '$tablesDir/codec_embedding_fp32.npy',
      mtpEmbPath: '$tablesDir/mtp_embeddings_fp16.npy',
      textEmbPath: '$tablesDir/text_embedding_fp16.npy',
      projectionNpzPath: '$tablesDir/text_projection_fp32.npz',
    );
    try {
      final rows = Float32List(3 * 2048);
      final rng = math.Random(7);
      for (var i = 0; i < rows.length; i++) {
        rows[i] = rng.nextDouble() * 2 - 1;
      }
      final out = t.projectText(rows);
      expect(out.length, 3 * 1024);
      expect(out.every((v) => v.isFinite), isTrue);
    } finally {
      t.dispose();
    }
  });
}
