// How the Multimodal RAG screen merges three indexes into one ranked list, and
// how it marks a query's words in a snippet. Pure Dart: unit-tested in
// test/knowledge_ranking_test.dart.
//
// EmbeddingGemma 2 puts text, images and audio in one space, but each kind of
// document has its own baseline: measured on this screen's sample set (740m,
// macOS CPU), a text query sits at cosine 0.52-0.60 to an unrelated note or
// photo and 0.55-0.70 to an unrelated voice memo, while the item a query is
// about scores 0.69-0.85 in every kind. Ranked by raw cosine, unrelated memos
// crowd out notes and photos. So each hit is ranked by its LIFT: its
// similarity minus the median similarity of the query to every document of
// its own kind — how far it stands out from the rest of its kind. On the
// sample set every query's intended item ranks first by lift; unrelated items
// stay within ±0.04 of their kind's median.

import 'dart:math' as math;

import 'multimodal_rag_item.dart';

/// Below this lift a hit is not shown (and not given to the language model):
/// unrelated items sit within ±0.04 of their kind's median.
const kMinLift = 0.05;

/// The lift at which a relevance bar is full; the sample set's best matches
/// lift 0.12-0.23.
const kFullLift = 0.20;

/// Fewer documents than this and a kind's median says nothing: its baseline
/// is then [kFallbackBaseline] instead.
const kMinDocsForMedian = 3;

/// Measured baselines (median cosine of a text query to unrelated documents
/// of each kind, EmbeddingGemma 2 on the sample set), used when a kind has
/// fewer than [kMinDocsForMedian] documents.
const kFallbackBaseline = <MultimodalRagKind, double>{
  MultimodalRagKind.note: 0.56,
  MultimodalRagKind.photo: 0.58,
  MultimodalRagKind.memo: 0.63,
};

/// One document's similarity to a query, from its kind's index.
typedef ScoredDocument = ({String id, double similarity});

/// A hit ranked across kinds.
final class RankedHit {
  const RankedHit({
    required this.id,
    required this.kind,
    required this.similarity,
    required this.lift,
  });

  final String id;
  final MultimodalRagKind kind;

  /// Cosine similarity to the query, as the index returned it.
  final double similarity;

  /// [similarity] minus the median similarity of the query to every document
  /// of [kind]: what the ranking uses.
  final double lift;

  /// [lift] on a 0-1 scale, for a relevance bar.
  double get strength => (lift / kFullLift).clamp(0.0, 1.0);

  @override
  String toString() =>
      'RankedHit($id, ${kind.name}, cos ${similarity.toStringAsFixed(3)}, '
      'lift ${lift.toStringAsFixed(3)})';
}

/// Ranks [scores] — every document of each kind with its similarity to one
/// query — by lift, strongest first, keeping those that lift at least
/// [minLift], at most [limit] of them.
List<RankedHit> rankAcrossKinds(
  Map<MultimodalRagKind, List<ScoredDocument>> scores, {
  double minLift = kMinLift,
  int limit = 8,
}) {
  final ranked = <RankedHit>[];
  for (final MapEntry(key: kind, value: documents) in scores.entries) {
    if (documents.isEmpty) continue;
    final baseline = documents.length >= kMinDocsForMedian
        ? _median([for (final d in documents) d.similarity])
        : kFallbackBaseline[kind]!;
    for (final document in documents) {
      ranked.add(
        RankedHit(
          id: document.id,
          kind: kind,
          similarity: document.similarity,
          lift: document.similarity - baseline,
        ),
      );
    }
  }
  ranked.sort((a, b) => b.lift.compareTo(a.lift));
  return [
    for (final hit in ranked)
      if (hit.lift >= minLift) hit,
  ].take(limit).toList();
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// A piece of a snippet: [text], marked when it matches a query word.
typedef SnippetPart = ({String text, bool match});

/// Words too common to mark.
const _stopWords = {
  'the',
  'and',
  'for',
  'are',
  'was',
  'what',
  'did',
  'say',
  'about',
  'with',
  'how',
  'much',
  'will',
  'that',
  'this',
  'from',
  'have',
  'has',
  'when',
  'where',
  'who',
  'why',
  'which',
  'you',
  'your',
  'my',
  'me',
  'our',
  'it',
  'its',
  'is',
  'of',
  'to',
  'in',
  'on',
  'at',
  'a',
  'an',
  'do',
  'does',
  'can',
  'should',
  'would',
  'could',
  'there',
  'their',
  'them',
  'they',
  'back',
};

/// The words of [query] worth marking: three letters or more, not a stop
/// word, lower-cased.
Set<String> queryTerms(String query) => {
  for (final word in query.toLowerCase().split(RegExp(r"[^a-z0-9']+")))
    if (word.length >= 3 && !_stopWords.contains(word)) word,
};

/// Splits [text] into parts, marking every word that starts with a query
/// term's stem (its first five letters at most: "delayed" marks "delay").
List<SnippetPart> highlight(String text, String query) {
  final stems = {
    for (final term in queryTerms(query))
      term.substring(0, math.min(term.length, 5)),
  };
  if (stems.isEmpty || text.isEmpty) return [(text: text, match: false)];
  final parts = <SnippetPart>[];
  var plainStart = 0;
  for (final word in RegExp(r"[A-Za-z0-9']+").allMatches(text)) {
    final lower = word.group(0)!.toLowerCase();
    if (!stems.any(lower.startsWith)) continue;
    if (word.start > plainStart) {
      parts.add((text: text.substring(plainStart, word.start), match: false));
    }
    parts.add((text: word.group(0)!, match: true));
    plainStart = word.end;
  }
  if (plainStart < text.length) {
    parts.add((text: text.substring(plainStart), match: false));
  }
  return parts;
}
