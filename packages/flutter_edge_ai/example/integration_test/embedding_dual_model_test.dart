import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

/// Integration test verifying both tokenizer types via public API.
///
/// EmbeddingGemma uses BPE tokenizer, Gecko uses Unigram tokenizer.
/// On iOS, tokenizer.json is auto-detected by model.type field in EmbeddingModel.swift.
/// On Android, SentencePiece C++ handles both formats natively.
///
/// Run: flutter test integration_test/embedding_dual_model_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const queryText = 'Which planet is known as the Red Planet';
  const similarText = 'Mars is famous for its reddish appearance';
  const differentText = 'The stock market closed higher today';

  double cosineSimilarity(List<double> a, List<double> b) {
    assert(a.length == b.length);
    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  Future<void> verifyEmbeddings(
    EmbeddingModel model,
    String label, {
    double minSimThreshold = 0.5,
    double maxDiffThreshold = 0.3,
  }) async {
    final queryEmb = await model.generateEmbedding(queryText);
    expect(queryEmb, isNotEmpty, reason: '$label: empty embeddings');
    expect(queryEmb.any((v) => v != 0), isTrue, reason: '$label: all zeros');

    final queryEmb2 = await model.generateEmbedding(queryText);
    expect(queryEmb.length, equals(queryEmb2.length));
    for (int i = 0; i < queryEmb.length; i++) {
      expect(
        queryEmb[i],
        closeTo(queryEmb2[i], 1e-6),
        reason: '$label: not repeatable at index $i',
      );
    }

    final similarEmb = await model.generateEmbedding(similarText);
    final simScore = cosineSimilarity(queryEmb, similarEmb);
    print('$label simSimilarity: $simScore');
    expect(
      simScore,
      greaterThan(minSimThreshold),
      reason: '$label: similar texts too different ($simScore)',
    );

    final diffEmb = await model.generateEmbedding(differentText);
    final diffScore = cosineSimilarity(queryEmb, diffEmb);
    print('$label diffSimilarity: $diffScore');
    expect(
      diffScore,
      lessThan(maxDiffThreshold),
      reason: '$label: different texts too similar ($diffScore)',
    );
  }

  testWidgets(
    'Embedding: EmbeddingGemma (BPE) + Gecko (Unigram)',
    (tester) async {
      await registerTestEngines();

      // --- EmbeddingGemma ---
      await FlutterEdgeAi.installEmbedder()
          .modelFromAsset(
            'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite',
          )
          .tokenizerFromAsset('assets/models/sentencepiece.model')
          .install();

      var model = await FlutterEdgeAi.getActiveEmbedder();
      try {
        await verifyEmbeddings(model, 'EmbeddingGemma-BPE');
      } finally {
        await model.close();
      }

      // --- Gecko 64 ---
      await FlutterEdgeAi.installEmbedder()
          .modelFromAsset('assets/models/Gecko_64_quant.tflite')
          .tokenizerFromAsset('assets/models/sentencepiece.model')
          .install();

      model = await FlutterEdgeAi.getActiveEmbedder();
      try {
        await verifyEmbeddings(
          model,
          'Gecko64-Unigram',
          minSimThreshold: 0.3,
          maxDiffThreshold: 0.7,
        );
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
