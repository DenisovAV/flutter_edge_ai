import 'vector_store.dart';

/// A single hit from a store's text search.
///
/// [relevanceScore] is the store's own text relevance: higher is better, and
/// it is comparable only within the results of one call. It is not a cosine
/// similarity and has no fixed scale (the SQLite store reports `-bm25()`).
final class TextSearchResult {
  const TextSearchResult({
    required this.id,
    required this.content,
    required this.relevanceScore,
    this.metadata,
  });

  final String id;
  final String content;
  final double relevanceScore;
  final String? metadata;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextSearchResult &&
          other.id == id &&
          other.content == content &&
          other.relevanceScore == relevanceScore &&
          other.metadata == metadata;

  @override
  int get hashCode => Object.hash(id, content, relevanceScore, metadata);

  @override
  String toString() =>
      'TextSearchResult(id: $id, relevanceScore: $relevanceScore, '
      'metadata: $metadata)';
}

/// A single hit from a hybrid (vector + text) search.
///
/// [rrfScore] is the fused score results are ordered by. The vector fields
/// ([vectorSimilarity], [vectorRank]) and the text fields ([relevanceScore],
/// [textRank]) report each leg separately; ranks start at 1. A null leg field
/// means the document was not among that leg's candidates: for the vector
/// leg, beyond its candidate window; for the text leg, without any query term
/// or beyond the window.
final class HybridSearchResult {
  const HybridSearchResult({
    required this.id,
    required this.content,
    required this.rrfScore,
    this.metadata,
    this.vectorSimilarity,
    this.vectorRank,
    this.relevanceScore,
    this.textRank,
  });

  final String id;
  final String content;
  final String? metadata;
  final double rrfScore;

  /// Cosine similarity from the vector leg.
  final double? vectorSimilarity;
  final int? vectorRank;

  /// The store's text relevance from the text leg (see [TextSearchResult]).
  final double? relevanceScore;
  final int? textRank;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HybridSearchResult &&
          other.id == id &&
          other.content == content &&
          other.metadata == metadata &&
          other.rrfScore == rrfScore &&
          other.vectorSimilarity == vectorSimilarity &&
          other.vectorRank == vectorRank &&
          other.relevanceScore == relevanceScore &&
          other.textRank == textRank;

  @override
  int get hashCode => Object.hash(
    id,
    content,
    metadata,
    rrfScore,
    vectorSimilarity,
    vectorRank,
    relevanceScore,
    textRank,
  );

  @override
  String toString() =>
      'HybridSearchResult(id: $id, rrfScore: $rrfScore, '
      'vectorSimilarity: $vectorSimilarity, vectorRank: $vectorRank, '
      'relevanceScore: $relevanceScore, textRank: $textRank, '
      'metadata: $metadata)';
}

/// How a hybrid search fuses its vector and text results.
///
/// Implemented only by this package; more methods may be added later.
abstract final class HybridFusion {
  const HybridFusion._();

  /// Throws [ArgumentError] when this fusion's parameters are invalid.
  void _validate();

  /// The fused score of a document at [vectorRank] and [textRank] (1-based;
  /// null when that leg did not return it).
  double _score(int? vectorRank, int? textRank);
}

/// Package-internal: throws [ArgumentError] when [fusion]'s parameters are
/// invalid.
void validateHybridFusion(HybridFusion fusion) => fusion._validate();

/// Reciprocal Rank Fusion: a document scores `1 / (k + rank)` in each leg
/// that returned it, summed over the legs. Ranks start at 1.
///
/// Rank-based, so the legs' scores never need to share a scale.
final class RrfFusion extends HybridFusion {
  /// [k] must be greater than 0; 60 is the value from the original paper.
  const RrfFusion({this.k = 60}) : super._();

  final int k;

  @override
  void _validate() {
    if (k <= 0) {
      throw ArgumentError.value(k, 'fusion.k', 'must be greater than 0');
    }
  }

  @override
  double _score(int? vectorRank, int? textRank) =>
      (vectorRank == null ? 0.0 : 1 / (k + vectorRank)) +
      (textRank == null ? 0.0 : 1 / (k + textRank));

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RrfFusion && other.k == k;

  @override
  int get hashCode => k.hashCode;

  @override
  String toString() => 'RrfFusion(k: $k)';
}

/// Package-internal: fuses [vector] and [text], each already in its leg's
/// rank order, and returns the first [topK].
///
/// Each id appears once; a leg that returns an id twice keeps its first
/// (best) rank, and a rank is the position in the leg's list. Content and
/// metadata come from the vector leg when both legs returned the id. Order: fused score descending, then id
/// ascending, so equal scores are deterministic.
List<HybridSearchResult> fuseHybridResults({
  required List<RetrievalResult> vector,
  required List<TextSearchResult> text,
  required HybridFusion fusion,
  required int topK,
}) {
  final entries = <String, _Fused>{};
  var rank = 0;
  for (final hit in vector) {
    rank++;
    // A store must not return an id twice; if one does, its best rank wins.
    if (entries.containsKey(hit.id)) continue;
    entries[hit.id] = _Fused(hit.id, hit.content, hit.metadata)
      ..vectorSimilarity = hit.similarity
      ..vectorRank = rank;
  }
  rank = 0;
  for (final hit in text) {
    rank++;
    final entry = entries.putIfAbsent(
      hit.id,
      () => _Fused(hit.id, hit.content, hit.metadata),
    );
    if (entry.textRank != null) continue;
    entry
      ..relevanceScore = hit.relevanceScore
      ..textRank = rank;
  }
  final results = [
    for (final entry in entries.values)
      HybridSearchResult(
        id: entry.id,
        content: entry.content,
        metadata: entry.metadata,
        rrfScore: fusion._score(entry.vectorRank, entry.textRank),
        vectorSimilarity: entry.vectorSimilarity,
        vectorRank: entry.vectorRank,
        relevanceScore: entry.relevanceScore,
        textRank: entry.textRank,
      ),
  ];
  results.sort((a, b) {
    final byScore = b.rrfScore.compareTo(a.rrfScore);
    return byScore != 0 ? byScore : a.id.compareTo(b.id);
  });
  return results.length > topK ? results.sublist(0, topK) : results;
}

class _Fused {
  _Fused(this.id, this.content, this.metadata);

  final String id;
  final String content;
  final String? metadata;
  double? vectorSimilarity;
  int? vectorRank;
  double? relevanceScore;
  int? textRank;
}
