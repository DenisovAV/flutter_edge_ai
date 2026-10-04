// Integration test: diagnose RAG ranking quality with EmbeddingGemma.
// Uses model from assets (no network download).
// Run: flutter test integration_test/embedding_rag_diagnosis_test.dart -d macos

import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath =
    'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerPath = 'assets/models/sentencepiece.model';

const _documents = {
  'flutter_intro':
      'Flutter is an open-source UI framework by Google for building natively compiled applications for mobile, web, and desktop from a single codebase.',
  'dart_language':
      'Dart is a client-optimized programming language for fast apps on multiple platforms. It is developed by Google and used to build Flutter applications.',
  'flutter_widgets':
      'In Flutter, everything is a widget. Widgets describe what their view should look like given their current configuration and state.',
  'flutter_hot_reload':
      'Flutter hot reload helps you quickly experiment, build UIs, add features, and fix bugs by injecting updated source code into the running Dart VM.',
  'flutter_state':
      'Flutter uses setState() for simple state management in StatefulWidget. For complex apps, consider using Provider, Riverpod, or BLoC pattern.',
  'flutter_platforms':
      'Flutter supports iOS, Android, web, Windows, macOS, and Linux platforms, allowing developers to create cross-platform applications efficiently.',
  'dart_null_safety':
      'Dart null safety helps catch null reference errors at compile time. Use nullable types with ? and null-aware operators like ?? and ?. for safer code.',
  'flutter_performance':
      'Flutter achieves high performance by compiling to native ARM code and using Skia graphics engine for rendering at 60fps or higher.',
};

const _queries = [
  'flutter',
  'What is Flutter?',
  'Flutter framework',
  'null safety in Dart',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'RAG ranking diagnosis with EmbeddingGemma',
    (tester) async {
      await registerTestEngines();

      await FlutterEdgeAi.installEmbedder()
          .modelFromAsset(_modelPath)
          .tokenizerFromAsset(_tokenizerPath)
          .install();

      final model = await FlutterEdgeAi.getActiveEmbedder();

      try {
        print('\n\n========== RAW embeddings ==========');
        final docEmbRaw = <String, List<double>>{};
        for (final entry in _documents.entries) {
          docEmbRaw[entry.key] = await model.generateEmbedding(entry.value);
        }
        for (final query in _queries) {
          final queryEmb = await model.generateEmbedding(query);
          _printRanking(query, queryEmb, docEmbRaw);
        }

        print('\n\n========== L2 NORMALIZED embeddings ==========');
        final docEmbNorm = <String, List<double>>{};
        for (final entry in docEmbRaw.entries) {
          docEmbNorm[entry.key] = _l2Normalize(entry.value);
        }
        for (final query in _queries) {
          final queryEmb = _l2Normalize(await model.generateEmbedding(query));
          _printRanking(query, queryEmb, docEmbNorm);
        }
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

void _printRanking(
  String query,
  List<double> queryEmb,
  Map<String, List<double>> docEmbs,
) {
  final scores = <String, double>{};
  for (final entry in docEmbs.entries) {
    scores[entry.key] = _cosineSimilarity(queryEmb, entry.value);
  }
  final sorted = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  print('\n=== Query: "$query" ===');
  for (var i = 0; i < sorted.length; i++) {
    print(
      '  ${i + 1}. ${sorted[i].key}: ${sorted[i].value.toStringAsFixed(6)}',
    );
  }
}

List<double> _l2Normalize(List<double> v) {
  double norm = 0;
  for (final x in v) norm += x * x;
  norm = math.sqrt(norm);
  if (norm == 0) return v;
  return v.map((x) => x / norm).toList();
}

double _cosineSimilarity(List<double> a, List<double> b) {
  double dot = 0, normA = 0, normB = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}
