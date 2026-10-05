// ignore_for_file: avoid_print

// Integration test: embeddings through Genkit API.
// Run: flutter test integration_test/embedder_test.dart -d <device>
//
// Requires embedding model assets in example/assets/models/:
// - embeddinggemma-300M_seq256_mixed-precision.tflite
// - sentencepiece.model

import 'dart:math' as math;

import 'package:flutter_gemma/flutter_gemma.dart' hide Message;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';

import 'test_helpers.dart';

void main() {
  initIntegrationTest();

  late Genkit ai;

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

  testWidgets('Embedder: setUpAll — install model + embedder', (tester) async {
    await initializeGemmaForTest();
    await ensureModelInstalled();

    await FlutterGemma.installEmbedder()
        .modelFromAsset(
            'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite')
        .tokenizerFromAsset('assets/models/sentencepiece.model')
        .install();

    ai = createTestGenkitWithEmbedder();
  }, timeout: const Timeout(kInstallTimeout));

  testWidgets('Embedder: single document embedding', (tester) async {
    final embeddings = await ai.embed(
      embedder: testEmbedderRef,
      document: DocumentData(
        content: [TextPart(text: queryText)],
      ),
    );

    expect(embeddings, hasLength(1));
    final vector = embeddings.first.embedding;
    print('[Embedder] Single: ${vector.length} dimensions');
    expect(vector, isNotEmpty, reason: 'Embedding vector should be non-empty');
    expect(vector.any((v) => v != 0), isTrue,
        reason: 'Embedding should have non-zero values');
  }, timeout: const Timeout(kInferenceTimeout));

  testWidgets('Embedder: batch embedding (3 documents)', (tester) async {
    final embeddings = await ai.embed(
      embedder: testEmbedderRef,
      documents: [
        DocumentData(content: [TextPart(text: queryText)]),
        DocumentData(content: [TextPart(text: similarText)]),
        DocumentData(content: [TextPart(text: differentText)]),
      ],
    );

    expect(embeddings, hasLength(3));
    for (int i = 0; i < embeddings.length; i++) {
      final vec = embeddings[i].embedding;
      expect(vec, isNotEmpty, reason: 'Embedding $i should be non-empty');
      print('[Embedder] Batch[$i]: ${vec.length} dimensions');
    }
  }, timeout: const Timeout(kInferenceTimeout));

  testWidgets('Embedder: cosine similarity — similar > different',
      (tester) async {
    final embeddings = await ai.embed(
      embedder: testEmbedderRef,
      documents: [
        DocumentData(content: [TextPart(text: queryText)]),
        DocumentData(content: [TextPart(text: similarText)]),
        DocumentData(content: [TextPart(text: differentText)]),
      ],
    );

    final queryEmb = embeddings[0].embedding;
    final similarEmb = embeddings[1].embedding;
    final diffEmb = embeddings[2].embedding;

    final simSimilarity = cosineSimilarity(queryEmb, similarEmb);
    final diffSimilarity = cosineSimilarity(queryEmb, diffEmb);

    print('[Embedder] Similar cosine: $simSimilarity');
    print('[Embedder] Different cosine: $diffSimilarity');

    expect(simSimilarity, greaterThan(diffSimilarity),
        reason:
            'Similar text should have higher cosine similarity than different text');
    expect(simSimilarity, greaterThan(0.5),
        reason: 'Similar texts should have similarity > 0.5');
    expect(diffSimilarity, lessThan(0.5),
        reason: 'Different texts should have similarity < 0.5');
  }, timeout: const Timeout(kInferenceTimeout));
}
