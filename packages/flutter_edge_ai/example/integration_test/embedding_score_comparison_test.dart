// Cross-platform embedding score comparison test.
// Uses model from assets (no network download).
// Run on Android: flutter test integration_test/embedding_score_comparison_test.dart -d <device>
// Run on macOS:   flutter test integration_test/embedding_score_comparison_test.dart -d macos

import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath =
    'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerPath = 'assets/models/sentencepiece.model';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Embedding score comparison', (WidgetTester tester) async {
    await registerTestEngines();

    await FlutterEdgeAi.installEmbedder()
        .modelFromAsset(_modelPath)
        .tokenizerFromAsset(_tokenizerPath)
        .install();

    final model = await FlutterEdgeAi.getActiveEmbedder();

    try {
      final queryEmb = await model.generateEmbedding(
        'Which planet is known as the Red Planet',
      );
      final similarEmb = await model.generateEmbedding(
        'Mars is famous for its reddish appearance',
      );
      final diffEmb = await model.generateEmbedding(
        'The stock market closed higher today',
      );

      final simScore = _cosineSimilarity(queryEmb, similarEmb);
      final diffScore = _cosineSimilarity(queryEmb, diffEmb);

      print('=== SCORES ===');
      print('Similar score: $simScore');
      print('Different score: $diffScore');
      print('Gap: ${simScore - diffScore}');
      print('Dimension: ${queryEmb.length}');

      expect(queryEmb.length, equals(768));
      expect(diffScore, lessThan(simScore));
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

double _cosineSimilarity(List<double> a, List<double> b) {
  assert(a.length == b.length);
  double dot = 0, normA = 0, normB = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}
