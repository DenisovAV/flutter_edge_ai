// Host smoke test — REAL ONNX Runtime sessions over REAL embedding models,
// through the real `dart:ffi` `OrtFfiClient` + the production tokenizer
// router `resolveEmbeddingTokenizer` (Phase 2 exit-gate evidence, Task 5).
// Not fakes: this is the one file in this package that actually dlopens
// `libonnxruntime` and runs real forward passes end-to-end, through
// `OnnxEmbeddingPass` exactly as core's worker drives it (load → embed →
// close).
//
// Two independently-skippable models exercise the two output layouts:
//   - Model A: all-MiniLM-L6-v2 (WordPiece, `last_hidden_state` -> tokenLevel
//     contract, masked mean-pool + L2-normalize).
//   - Model B: EmbeddingGemma-300M-ONNX (SentencePiece, `sentence_embedding`
//     -> pooledFinal contract, copied verbatim).
//
// Guarded to skip cleanly when the dylib/models aren't available locally
// (multi-hundred-MB downloads, not checked in) — set:
//   FLUTTER_GEMMA_ORT_LIBRARY=/path/to/libonnxruntime.dylib
//   ONNX_SMOKE_MINILM_DIR=/path/to/dir/containing/model.onnx+tokenizer.json
//   ONNX_SMOKE_EMBEDDINGGEMMA_DIR=/path/to/dir/containing/model.onnx
//       (+ its external-data file next to it, named as the graph declares)
//       +tokenizer.model (the RAW SentencePiece binary — NOT the HF
//       `tokenizer.json`, which is a different, incompatible BPE-vocab
//       schema our SentencePiece adapter cannot parse; same convention the
//       LiteRT path uses, see `embedding_golden_test.dart`).
// then `flutter test test/embedding/onnx_embedding_host_smoke_test.dart`.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — the embeddings tokenizer router is not exported; the smoke test builds tokenizers through it
import 'package:flutter_edge_ai_embeddings/src/tokenizer_router.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/onnx_embedding_pass.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/ort_ffi_client.dart';
import 'package:flutter_test/flutter_test.dart';

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

OnnxEmbeddingPass _pass(String modelPath, String tokenizerPath) =>
    OnnxEmbeddingPass(
      OnnxEmbeddingConfig(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        tokenizerFactory: resolveEmbeddingTokenizer,
      ),
      clientFactory: OrtFfiClient.new,
    );

/// No task prefix: these models were scored raw.
Future<List<double>> _embed(OnnxEmbeddingPass pass, String text) =>
    pass.embed(EmbeddingInput.text(text), TaskType.none);

void main() {
  final libraryPath = Platform.environment['FLUTTER_GEMMA_ORT_LIBRARY'];

  test('Model A (all-MiniLM-L6-v2, WordPiece, tokenLevel contract): dim=384, '
      'cosine(similar) > cosine(different) with margin', () async {
    final modelDir = Platform.environment['ONNX_SMOKE_MINILM_DIR'];
    final runnable =
        libraryPath != null &&
        File(libraryPath).existsSync() &&
        modelDir != null &&
        File('$modelDir/model.onnx').existsSync() &&
        File('$modelDir/tokenizer.json').existsSync();
    if (!runnable) {
      markTestSkipped(
        'FLUTTER_GEMMA_ORT_LIBRARY / ONNX_SMOKE_MINILM_DIR not set or the '
        'files are absent locally — see this file\'s header.',
      );
      return;
    }

    final pass = _pass('$modelDir/model.onnx', '$modelDir/tokenizer.json');
    try {
      final info = await pass.load();
      expect(info.dimension, 384);

      final a = await _embed(pass, 'The cat sat on the mat.');
      final b = await _embed(pass, 'A feline rested on the rug.');
      final c = await _embed(pass, 'Quantum entanglement baffles physicists.');

      final simSimilar = _cosine(a, b);
      final simDifferent = _cosine(a, c);
      // ignore: avoid_print
      print(
        'ONNX MiniLM smoke: cosine(similar)=$simSimilar '
        'cosine(different)=$simDifferent dim=${info.dimension} '
        'maxInputTokens=${info.maxInputTokens}',
      );
      expect(
        simSimilar,
        greaterThan(simDifferent + 0.1),
        reason:
            'similar-meaning sentences must score meaningfully higher '
            'than an unrelated one',
      );
    } finally {
      await pass.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'Model B (EmbeddingGemma-300M-ONNX, SentencePiece, pooledFinal contract): '
    'dim=768, cosine(similar) > cosine(different) with margin',
    () async {
      final modelDir = Platform.environment['ONNX_SMOKE_EMBEDDINGGEMMA_DIR'];
      final runnable =
          libraryPath != null &&
          File(libraryPath).existsSync() &&
          modelDir != null &&
          File('$modelDir/model.onnx').existsSync() &&
          File('$modelDir/tokenizer.model').existsSync();
      if (!runnable) {
        markTestSkipped(
          'FLUTTER_GEMMA_ORT_LIBRARY / ONNX_SMOKE_EMBEDDINGGEMMA_DIR not set '
          'or the files are absent locally — see this file\'s header.',
        );
        return;
      }

      final pass = _pass('$modelDir/model.onnx', '$modelDir/tokenizer.model');
      try {
        final info = await pass.load();
        expect(info.dimension, 768);

        final a = await _embed(pass, 'The cat sat on the mat.');
        final b = await _embed(pass, 'A feline rested on the rug.');
        final c = await _embed(
          pass,
          'Quantum entanglement baffles physicists.',
        );

        final simSimilar = _cosine(a, b);
        final simDifferent = _cosine(a, c);
        // ignore: avoid_print
        print(
          'ONNX EmbeddingGemma smoke: cosine(similar)=$simSimilar '
          'cosine(different)=$simDifferent dim=${info.dimension} '
          'maxInputTokens=${info.maxInputTokens}',
        );
        expect(
          simSimilar,
          greaterThan(simDifferent + 0.05),
          reason:
              'similar-meaning sentences must score meaningfully higher '
              'than an unrelated one',
        );
      } finally {
        await pass.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
