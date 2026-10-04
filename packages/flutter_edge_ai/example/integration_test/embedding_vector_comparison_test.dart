// Integration test: compare embedding vectors across platforms.
// Uses model from assets (no network download).
// Run on macOS:   flutter test integration_test/embedding_vector_comparison_test.dart -d macos
// Run on Android: flutter test integration_test/embedding_vector_comparison_test.dart -d <device_id>

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath =
    'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerPath = 'assets/models/sentencepiece.model';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Embedding vector comparison', (tester) async {
    final platform = defaultTargetPlatform.name;
    print('=== Platform: $platform ===');

    await registerTestEngines();

    await FlutterEdgeAi.installEmbedder()
        .modelFromAsset(_modelPath)
        .tokenizerFromAsset(_tokenizerPath)
        .install();

    final embedder = await FlutterEdgeAi.getActiveEmbedder();

    final testPhrases = [
      'Hello world',
      'The cat sat on the mat',
      'Machine learning is fascinating',
    ];

    for (final phrase in testPhrases) {
      final embedding = await embedder.generateEmbedding(phrase);
      final dim = embedding.length;

      final first10 = embedding
          .take(10)
          .map((v) => v.toStringAsFixed(6))
          .join(', ');
      final last5 = embedding
          .skip(dim - 5)
          .map((v) => v.toStringAsFixed(6))
          .join(', ');

      double norm = 0;
      for (final v in embedding) {
        norm += v * v;
      }
      norm = norm > 0 ? norm : 0;

      print('');
      print('--- "$phrase" ---');
      print('[$platform] dim=$dim, norm=${norm.toStringAsFixed(6)}');
      print('[$platform] first10: [$first10]');
      print('[$platform] last5:  [$last5]');
    }

    final emb1 = await embedder.generateEmbedding(testPhrases[0]);
    final emb2 = await embedder.generateEmbedding(testPhrases[1]);
    final emb3 = await embedder.generateEmbedding(testPhrases[2]);

    double cosine(List<double> a, List<double> b) {
      double dot = 0, na = 0, nb = 0;
      for (int i = 0; i < a.length; i++) {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
      }
      if (na == 0 || nb == 0) return 0;
      return dot / (na * nb > 0 ? (na * nb) : 1);
    }

    print('');
    print('=== Cosine similarities ===');
    print(
      '[$platform] "Hello world" vs "The cat sat on the mat": ${cosine(emb1, emb2).toStringAsFixed(6)}',
    );
    print(
      '[$platform] "Hello world" vs "Machine learning": ${cosine(emb1, emb3).toStringAsFixed(6)}',
    );
    print(
      '[$platform] "The cat" vs "Machine learning": ${cosine(emb2, emb3).toStringAsFixed(6)}',
    );

    await embedder.close();
  });
}
