import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_flutter_edge_ai/genkit_flutter_edge_ai.dart';

const List<String> _cityFiles = [
  'paris',
  'tokyo',
  'new_york',
  'barcelona',
  'istanbul',
  'sydney',
  'rio',
  'marrakech',
  'prague',
  'singapore',
];

/// Cosine floor a city guide must clear to count as relevant to the query.
const kMinSimilarity = 0.5;

/// How many of the surviving guides go into the prompt.
const kTopK = 3;

class _VectorDocument {
  final String id;
  final String content;
  final String city;
  final List<double> embedding;

  const _VectorDocument({
    required this.id,
    required this.content,
    required this.city,
    required this.embedding,
  });
}

/// RAG service for tourist-guide semantic search.
///
/// Accepts a pre-initialized [Genkit] instance and embedder name from the
/// caller so it stays decoupled from flutter_edge_ai lifecycle management.
/// The caller (LocalAIService) owns model/embedder installation.
class RagService {
  final Genkit _ai;
  final String _embedderName;
  final List<_VectorDocument> _store = [];
  bool _isInitialized = false;

  RagService({required this._ai, required this._embedderName});

  Future<void> initialize({void Function(String status)? onStatus}) async {
    if (_isInitialized) return;

    onStatus?.call('Loading tourist data...');
    await _loadTouristData(onStatus);

    _isInitialized = true;
    onStatus?.call('RAG ready (${_store.length} documents)');
  }

  Future<void> _loadTouristData(void Function(String)? onStatus) async {
    for (final city in _cityFiles) {
      onStatus?.call('Embedding $city...');
      final jsonString = await rootBundle.loadString(
        'assets/tourist_data/$city.json',
      );
      final data = jsonDecode(jsonString) as Map<String, dynamic>;

      final name = data['name'] as String? ?? city;
      final content = _buildContent(data);

      final embeddings = await _ai.embed(
        embedder: flutterEdgeAi.embedder(_embedderName),
        document: DocumentData(content: [TextPart(text: content)]),
      );

      _store.add(
        _VectorDocument(
          id: city,
          content: content,
          city: name,
          embedding: embeddings.first.embedding,
        ),
      );
    }
  }

  String _buildContent(Map<String, dynamic> data) {
    final description = data['description'] as String? ?? '';
    final attractions = ((data['attractions'] as List?) ?? []).join(', ');
    final cuisine = ((data['cuisine'] as List?) ?? []).join(', ');
    final bestTime = data['best_time'] as String? ?? '';
    final funFact = data['fun_fact'] as String? ?? '';
    return '$description\n\n'
        'Top attractions: $attractions.\n'
        'Local cuisine: $cuisine.\n'
        'Best time to visit: $bestTime.\n'
        'Fun fact: $funFact';
  }

  Future<RagResult> searchAndBuildContext(String query) async {
    if (!_isInitialized) throw StateError('RagService not initialized');

    final queryEmbeddings = await _ai.embed(
      embedder: flutterEdgeAi.embedder(_embedderName),
      document: DocumentData(content: [TextPart(text: query)]),
    );
    final queryVector = queryEmbeddings.first.embedding;

    final scored =
        _store
            .map(
              (doc) => (doc: doc, score: _cosine(queryVector, doc.embedding)),
            )
            .where((r) => r.score >= kMinSimilarity)
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));

    final topK = scored.take(kTopK).toList();

    if (topK.isEmpty) {
      return RagResult(
        augmentedPrompt: query,
        retrievedContext: '',
        sources: [],
      );
    }

    final context = topK.map((r) => r.doc.content).join('\n\n');
    final sources = topK
        .map((r) => '${r.doc.city} (${(r.score * 100).toStringAsFixed(0)}%)')
        .toList();

    final augmentedPrompt =
        'Based on the following travel information:\n\n$context\n\n'
        'Answer the question: $query';

    return RagResult(
      augmentedPrompt: augmentedPrompt,
      retrievedContext: context,
      sources: sources,
    );
  }

  double _cosine(List<double> a, List<double> b) {
    // Not an assert: asserts are stripped from release builds, and a
    // dimension mismatch there would silently score garbage.
    if (a.length != b.length) {
      throw ArgumentError(
        'Embedding dimensions must match: ${a.length} != ${b.length}',
      );
    }
    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    final denom = math.sqrt(normA) * math.sqrt(normB);
    return denom == 0 ? 0.0 : dot / denom;
  }

  void dispose() {
    _store.clear();
    _isInitialized = false;
  }
}

class RagResult {
  final String augmentedPrompt;
  final String retrievedContext;
  final List<String> sources;

  const RagResult({
    required this.augmentedPrompt,
    required this.retrievedContext,
    required this.sources,
  });

  bool get hasContext => retrievedContext.isNotEmpty;
}
