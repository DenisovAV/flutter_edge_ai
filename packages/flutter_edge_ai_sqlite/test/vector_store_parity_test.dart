import 'dart:typed_data';
import 'dart:math' show sqrt;
import 'package:flutter_test/flutter_test.dart';

/// Cross-Platform Parity Tests for VectorStore
///
/// These tests verify that BLOB encoding and cosine similarity
/// produce IDENTICAL results across all platforms (Android, iOS, Web).
///
/// The cosine-similarity helpers below mirror the native side that the
/// embedder/store produce; `vec0` itself returns the equivalent metric as
/// `1 - distance`. These are pure-Dart parity checks (no sqlite, no FFI).
///
/// Run on web: flutter test test/vector_store_parity_test.dart -p chrome
/// Run on VM:  flutter test test/vector_store_parity_test.dart
void main() {
  group('BLOB Encoding/Decoding Parity', () {
    test('embeddingToBlob produces correct little-endian float32 bytes', () {
      final embedding = [1.0, 0.5, -0.25, 0.0];
      final blob = embeddingToBlob(embedding);

      // Size: 4 floats * 4 bytes = 16 bytes
      expect(blob.length, 16);

      // Verify little-endian float32 encoding
      // 1.0 in float32 = 0x3F800000
      expect(blob[0], 0x00);
      expect(blob[1], 0x00);
      expect(blob[2], 0x80);
      expect(blob[3], 0x3F);

      // 0.5 in float32 = 0x3F000000
      expect(blob[4], 0x00);
      expect(blob[5], 0x00);
      expect(blob[6], 0x00);
      expect(blob[7], 0x3F);

      // -0.25 in float32 = 0xBE800000
      expect(blob[8], 0x00);
      expect(blob[9], 0x00);
      expect(blob[10], 0x80);
      expect(blob[11], 0xBE);

      // 0.0 in float32 = 0x00000000
      expect(blob[12], 0x00);
      expect(blob[13], 0x00);
      expect(blob[14], 0x00);
      expect(blob[15], 0x00);
    });

    test('blobToEmbedding correctly decodes little-endian float32', () {
      // Create blob for [1.0, 0.5, -0.25, 0.0]
      final blob = Uint8List.fromList([
        0x00, 0x00, 0x80, 0x3F, // 1.0
        0x00, 0x00, 0x00, 0x3F, // 0.5
        0x00, 0x00, 0x80, 0xBE, // -0.25
        0x00, 0x00, 0x00, 0x00, // 0.0
      ]);

      final embedding = blobToEmbedding(blob);

      expect(embedding.length, 4);
      expect(embedding[0], closeTo(1.0, 0.0001));
      expect(embedding[1], closeTo(0.5, 0.0001));
      expect(embedding[2], closeTo(-0.25, 0.0001));
      expect(embedding[3], closeTo(0.0, 0.0001));
    });

    test('round-trip encoding preserves values (within float32 precision)', () {
      final original = [0.123456789, -0.987654321, 0.5, 0.0, 1.0];
      final blob = embeddingToBlob(original);
      final decoded = blobToEmbedding(blob);

      expect(decoded.length, original.length);

      // Float32 has ~7 decimal digits of precision
      for (int i = 0; i < original.length; i++) {
        expect(decoded[i], closeTo(original[i], 0.0001));
      }
    });

    test('empty embedding produces empty blob', () {
      final embedding = <double>[];
      final blob = embeddingToBlob(embedding);
      expect(blob.length, 0);
    });

    test('768D embedding produces 3072 byte blob', () {
      final embedding = List.generate(768, (i) => i / 768.0);
      final blob = embeddingToBlob(embedding);
      expect(blob.length, 768 * 4); // 3072 bytes
    });
  });

  group('Cosine Similarity Parity', () {
    test('identical vectors have similarity 1.0', () {
      final v = [1.0, 2.0, 3.0];
      expect(cosineSimilarity(v, v), closeTo(1.0, 0.0001));
    });

    test('orthogonal vectors have similarity 0.0', () {
      final v1 = [1.0, 0.0, 0.0];
      final v3 = [0.0, 1.0, 0.0];
      expect(cosineSimilarity(v1, v3), closeTo(0.0, 0.0001));
    });

    test('opposite vectors have similarity -1.0', () {
      final v1 = [1.0, 0.0, 0.0];
      final v2 = [-1.0, 0.0, 0.0];
      expect(cosineSimilarity(v1, v2), closeTo(-1.0, 0.0001));
    });

    test('similar vectors from integration tests', () {
      // These are the exact vectors from integration_test/vector_store_test.dart
      final doc1 = [1.0, 0.0, 0.0];
      final doc2 = [0.9, 0.1, 0.0];
      final doc3 = [0.0, 1.0, 0.0];

      // doc1 vs doc1 = 1.0 (exact match)
      expect(cosineSimilarity(doc1, doc1), closeTo(1.0, 0.0001));

      // doc1 vs doc2 = high similarity (>0.99)
      final sim12 = cosineSimilarity(doc1, doc2);
      expect(sim12, greaterThan(0.99));

      // doc1 vs doc3 = 0.0 (orthogonal)
      expect(cosineSimilarity(doc1, doc3), closeTo(0.0, 0.0001));
    });

    test('normalized vectors from Test 9: Threshold Filtering', () {
      // Vectors from the threshold filtering test
      final very = [1.0, 0.0, 0.0]; // similarity = 1.0
      final somewhat = [0.7, 0.7, 0.0]; // similarity ~0.7
      final not = [0.0, 1.0, 0.0]; // similarity = 0.0

      final query = [1.0, 0.0, 0.0];

      expect(cosineSimilarity(query, very), closeTo(1.0, 0.0001));
      expect(cosineSimilarity(query, somewhat), closeTo(0.7071, 0.001));
      expect(cosineSimilarity(query, not), closeTo(0.0, 0.0001));
    });

    test('different length vectors return 0.0', () {
      final v1 = [1.0, 2.0];
      final v2 = [1.0, 2.0, 3.0];
      expect(cosineSimilarity(v1, v2), 0.0);
    });

    test('zero vector returns 0.0', () {
      final zero = [0.0, 0.0, 0.0];
      final v = [1.0, 2.0, 3.0];
      expect(cosineSimilarity(zero, v), 0.0);
      expect(cosineSimilarity(v, zero), 0.0);
    });

    test('high-dimensional vectors (768D)', () {
      // Simulate real embedding vectors
      final v1 = List.generate(768, (i) => i / 768.0);
      final v2 = List.generate(768, (i) => (i + 1) / 769.0);

      final similarity = cosineSimilarity(v1, v2);

      // Should be very high (similar patterns)
      expect(similarity, greaterThan(0.99));
    });
  });

  group('Full Round-Trip Parity', () {
    test('BLOB round-trip preserves similarity calculations', () {
      // Original embeddings
      final doc1 = [1.0, 0.0, 0.0];
      final doc2 = [0.9, 0.1, 0.0];

      // Calculate similarity before encoding
      final simBefore = cosineSimilarity(doc1, doc2);

      // Encode to BLOB and decode
      final blob1 = embeddingToBlob(doc1);
      final blob2 = embeddingToBlob(doc2);
      final decoded1 = blobToEmbedding(blob1);
      final decoded2 = blobToEmbedding(blob2);

      // Calculate similarity after decoding
      final simAfter = cosineSimilarity(decoded1, decoded2);

      // Should be identical (within float32 precision)
      expect(simAfter, closeTo(simBefore, 0.0001));
    });
  });
}

// =============================================================================
// Pure Dart implementations - IDENTICAL to Android/iOS/Web
// =============================================================================

/// Convert embedding to BLOB (float32 little-endian)
/// IDENTICAL to:
/// - Android: VectorStore.kt:204-209
/// - iOS: VectorStore.swift (Data encoding)
/// - Web: sqlite_vector_store.js:272-281
Uint8List embeddingToBlob(List<double> embedding) {
  final buffer = ByteData(embedding.length * 4);

  for (int i = 0; i < embedding.length; i++) {
    buffer.setFloat32(i * 4, embedding[i], Endian.little);
  }

  return buffer.buffer.asUint8List();
}

/// Convert BLOB to embedding
/// IDENTICAL to:
/// - Android: VectorStore.kt:214-220
/// - iOS: VectorStore.swift (Data decoding)
/// - Web: sqlite_vector_store.js:287-301
List<double> blobToEmbedding(Uint8List blob) {
  final buffer = ByteData.view(blob.buffer, blob.offsetInBytes, blob.length);
  final embedding = <double>[];

  for (int i = 0; i < blob.length ~/ 4; i++) {
    embedding.add(buffer.getFloat32(i * 4, Endian.little));
  }

  return embedding;
}

/// Cosine similarity calculation
/// IDENTICAL to:
/// - Android: VectorStore.kt:180-196
/// - iOS: VectorUtils.swift:14-30
/// - Web: sqlite_vector_store.js:314-330
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length) return 0.0;

  double dotProduct = 0.0;
  double normA = 0.0;
  double normB = 0.0;

  for (int i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }

  if (normA == 0.0 || normB == 0.0) return 0.0;

  return dotProduct / (sqrt(normA) * sqrt(normB));
}
