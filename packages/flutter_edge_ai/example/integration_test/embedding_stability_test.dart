import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

/// Integration test for embedding model stability.
///
/// Run: flutter test integration_test/embedding_stability_test.dart -d macos
/// Run: flutter test integration_test/embedding_stability_test.dart -d emulator-5554
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

  testWidgets(
    'Embedding: install, generate, compare',
    (tester) async {
      await registerTestEngines();

      await FlutterEdgeAi.installEmbedder()
          .modelFromAsset(
            'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite',
          )
          .tokenizerFromAsset('assets/models/sentencepiece.model')
          .install();

      final model = await FlutterEdgeAi.getActiveEmbedder();

      try {
        // 1. Non-zero embeddings
        final queryEmb = await model.generateEmbedding(queryText);
        expect(queryEmb, isNotEmpty);
        expect(queryEmb.any((v) => v != 0), isTrue);

        // 2. Repeatability — same text produces identical embeddings
        final queryEmb2 = await model.generateEmbedding(queryText);
        expect(queryEmb.length, equals(queryEmb2.length));
        for (int i = 0; i < queryEmb.length; i++) {
          expect(queryEmb[i], closeTo(queryEmb2[i], 1e-6));
        }

        // 3. Similar texts — high cosine similarity
        final similarEmb = await model.generateEmbedding(similarText);
        final simSimilarity = cosineSimilarity(queryEmb, similarEmb);
        print('simSimilarity: $simSimilarity');
        expect(simSimilarity, greaterThan(0.5));

        // 4. Different texts — low cosine similarity
        final diffEmb = await model.generateEmbedding(differentText);
        final diffSimilarity = cosineSimilarity(queryEmb, diffEmb);
        print('diffSimilarity: $diffSimilarity');
        expect(diffSimilarity, lessThan(0.3));
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
