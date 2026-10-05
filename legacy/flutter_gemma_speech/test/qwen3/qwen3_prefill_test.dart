// Load + talker-prefill smoke test for `Qwen3TtsCore` — the second test in
// this package that loads real compiled `.tflite` graphs through our own
// Dart LiteRT FFI (after `qwen3_talker_layout_test.dart`), and the first
// that actually RUNS a forward pass (`runPrefill`) rather than only
// introspecting declared tensor layouts.
//
// This is a shape-only gate: it asserts `Qwen3TtsCore.load` succeeds, the
// introspected MTP/codec params look sane, and `runPrefill` — run on a real
// prompt built via the already-verified Phase-1 chain (`Qwen2BpeEncoder` +
// `Qwen3Tables` + `Qwen3Prompt`) — returns 56 finite, non-empty KV tensors
// without throwing. Token-for-token correctness (matching the golden first
// codebook-0 token) is Task 2.3's `runDecode` gate, not this one.
//
// The model bundle (~1.5 GB across the 3 graphs + tables) is NOT committed
// to the repo — it lives in the local HuggingFace cache (see
// [_defaultModelDir] below) or wherever `QWEN3_MODEL_DIR` points. When
// absent (e.g. CI without the artifact fetched) the test skips gracefully;
// when present (as for local device runs) it asserts the real load+prefill.
@Tags(['qwen3-artifacts'])
library;

import 'dart:io';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma_speech/src/qwen3/npy_reader.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen2_bpe_encoder.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_prompt.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_tables.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_talker_layout.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_tts_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Default location of the Qwen3-TTS model snapshot dir — the local
/// HuggingFace cache path for `litert-community/Qwen3-TTS-12Hz-0.6B-Base`.
/// Override with the `QWEN3_MODEL_DIR` environment variable to run against
/// a different snapshot. Mirrors `qwen3_talker_layout_test.dart`/
/// `qwen3_tables_test.dart`'s identical helper.
String _defaultModelDir() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.cache/huggingface/hub/'
      'models--litert-community--Qwen3-TTS-12Hz-0.6B-Base/snapshots/'
      '66855540b3b34679f06c3ff07859603fc9514c66';
}

String _modelDir() =>
    Platform.environment['QWEN3_MODEL_DIR'] ?? _defaultModelDir();

/// Recursively scans [dir] and returns a basename -> absolute-path map for
/// every regular file found. The talker/mtp/codec graphs + tokenizer sit
/// directly in the snapshot dir, the host tables under `tables/`, and the
/// demo voice under `voices/` — every basename is unique across the tree, so
/// a flat map is enough to build `Qwen3TtsCore.load`'s `artifactPaths`.
Map<String, String> _scanArtifactPaths(String dir) {
  final out = <String, String>{};
  for (final entity in Directory(dir).listSync(recursive: true)) {
    if (entity is File) {
      out[entity.uri.pathSegments.last] = entity.path;
    }
  }
  return out;
}

void main() {
  final modelDir = _modelDir();

  test('Qwen3TtsCore.load + runPrefill: real graphs load, prefill returns 56 '
      'finite KV tensors', () async {
    if (!Directory(modelDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model snapshot not found at $modelDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final artifactPaths = _scanArtifactPaths(modelDir);
    final core = await Qwen3TtsCore.load(
      artifactPaths: artifactPaths,
      backend: PreferredBackend.cpu,
    );
    try {
      expect(core.sampleRate, 24000);
      // recipe (qwen3_tts_pipeline.py Qwen3TtsPipeline.__init__): mtp_cache_len == 17 (16
      // MTP residual steps + 1).
      expect(core.mtpCacheLen, 17);
      expect(core.mtpKvShape, isNotEmpty);
      expect(core.codecChunk, greaterThan(0));

      // Real Phase-1 chain: encode -> build the talker prompt -> prefill.
      // Independent Qwen3Tables/Qwen2BpeEncoder instances (not the core's
      // internal ones) — mirrors how a real caller assembles a prompt
      // ahead of driving the core, and keeps this test's prompt-assembly
      // step verifiable against the already-covered `qwen3_prompt_test`/
      // `qwen3_tables_test` behavior.
      final tablesDir = '$modelDir/tables';
      final encoder = await Qwen2BpeEncoder.fromTokenizerJson(
        artifactPaths['tokenizer.json']!,
      );
      final tables = await Qwen3Tables.load(
        codecEmbPath: '$tablesDir/codec_embedding_fp32.npy',
        mtpEmbPath: '$tablesDir/mtp_embeddings_fp16.npy',
        textEmbPath: '$tablesDir/text_embedding_fp16.npy',
        projectionNpzPath: '$tablesDir/text_projection_fp32.npz',
      );
      try {
        final speaker = readNpyF32(artifactPaths['demo_speaker.npy']!);
        final ids = encoder.encode(
          '<|im_start|>assistant\n'
          'Hello, this is a test of the Qwen3 text to speech system.'
          '<|im_end|>\n<|im_start|>assistant\n',
        );
        final prompt = Qwen3Prompt.build(
          ids: ids,
          speaker: speaker,
          language: 'english',
          tables: tables,
        );

        final kv = core.runPrefill(prompt.prefill, prompt.promptLen);

        // ignore: avoid_print
        print(
          'QWEN3-PREFILL-TEST<<<promptLen=${prompt.promptLen} '
          'kvCount=${kv.length} kv0Shape.len=${kv[0].length} '
          'mtpCacheLen=${core.mtpCacheLen} mtpKvShape=${core.mtpKvShape} '
          'codecChunk=${core.codecChunk}>>>',
        );

        expect(kv.length, TalkerLayout.numKvTensors);
        for (var i = 0; i < kv.length; i++) {
          expect(kv[i].isNotEmpty, isTrue, reason: 'kv[$i] is empty');
          expect(
            kv[i].every((v) => v.isFinite),
            isTrue,
            reason: 'kv[$i] has non-finite values',
          );
        }
      } finally {
        tables.dispose();
      }
    } finally {
      core.dispose();
    }
  });
}
