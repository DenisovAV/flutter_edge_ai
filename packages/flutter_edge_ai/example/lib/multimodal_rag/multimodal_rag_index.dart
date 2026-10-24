import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import 'multimodal_rag_item.dart';
import 'multimodal_rag_ranking.dart';

/// Opens the index of one kind, bound to [embedder]. The app's wiring puts
/// each kind at its own SQLite location (one modality per location).
typedef MultimodalRagIndexOpener =
    Future<RagIndex> Function(MultimodalRagKind kind, RagEmbedder embedder);

/// The knowledge base's vectors: one RAG index per kind — notes (text),
/// photos (image), voice memos (audio) — in one EmbeddingGemma 2 space, and a
/// search that ranks the three together ([rankAcrossKinds]).
///
/// Owns its indexes (dispose them with [dispose]); borrows the embedder.
final class MultimodalRagIndex {
  MultimodalRagIndex._(this._indexes, this._embedders);

  /// Opens an index for each of [kinds], each through its own timed wrapper
  /// of `embedderFor(kind)`, so what one item cost is known.
  static Future<MultimodalRagIndex> open({
    required Set<MultimodalRagKind> kinds,
    required RagEmbedder Function(MultimodalRagKind kind) embedderFor,
    required MultimodalRagIndexOpener openIndex,
  }) async {
    final indexes = <MultimodalRagKind, RagIndex>{};
    final embedders = <MultimodalRagKind, TimedRagEmbedder>{};
    try {
      // One after another: the first open loads the model, the rest reuse it.
      for (final kind in MultimodalRagKind.values) {
        if (!kinds.contains(kind)) continue;
        final embedder = TimedRagEmbedder(embedderFor(kind));
        indexes[kind] = await openIndex(kind, embedder);
        embedders[kind] = embedder;
      }
    } catch (_) {
      for (final index in indexes.values) {
        await index.dispose();
      }
      rethrow;
    }
    final knowledge = MultimodalRagIndex._(indexes, embedders);
    await knowledge._refreshCounts();
    return knowledge;
  }

  final Map<MultimodalRagKind, RagIndex> _indexes;
  final Map<MultimodalRagKind, TimedRagEmbedder> _embedders;
  final Map<MultimodalRagKind, int> _counts = {};

  /// The kinds this index holds.
  Set<MultimodalRagKind> get kinds => _indexes.keys.toSet();

  /// How many documents each kind's index holds.
  Map<MultimodalRagKind, int> get counts => Map.unmodifiable(_counts);

  int get documentCount => _counts.values.fold(0, (sum, n) => sum + n);

  /// Embeds and stores [note]. Returns what embedding it took.
  Future<Duration> addNote(NoteItem note) => _add(
    MultimodalRagKind.note,
    id: note.id,
    document: EmbeddingInput.text(note.document),
    content: note.body,
  );

  /// Embeds and stores [photo] from [prepared] — the photo upright, at most
  /// 1024 px (`preparePhotoForEmbedding`). The index keeps its reference.
  Future<Duration> addPhoto(PhotoItem photo, Uint8List prepared) => _add(
    MultimodalRagKind.photo,
    id: photo.id,
    document: EmbeddingInput.image(prepared),
    content: photo.reference,
  );

  /// Embeds and stores [memo] from [audio] — encoded WAV, MP3 or FLAC bytes.
  /// The index keeps its reference; the sound is what is embedded, not the
  /// transcript.
  Future<Duration> addMemo(MemoItem memo, Uint8List audio) => _add(
    MultimodalRagKind.memo,
    id: memo.id,
    document: EmbeddingInput.audio(audio),
    content: memo.reference,
  );

  Future<Duration> _add(
    MultimodalRagKind kind, {
    required String id,
    required EmbeddingInput document,
    required String content,
  }) async {
    final index = _require(kind);
    await index.add(id: id, document: document, content: content);
    _counts[kind] = (await index.stats()).documentCount;
    return _embedders[kind]!.last ?? Duration.zero;
  }

  /// Searches every kind for [query] — a text query, so text → text,
  /// text → image and text → audio — and ranks the hits together by lift
  /// ([rankAcrossKinds]).
  Future<List<RankedHit>> search(String query, {int limit = 8}) =>
      searchBy(EmbeddingInput.text(query), limit: limit);

  /// Searches [kinds] (every kind by default) with [query] — text, a photo
  /// or a recording — leaving out the documents in [exclude], and ranks the
  /// hits together by lift ([rankAcrossKinds]). Each kind is searched over
  /// all its documents: the lift needs the kind's median.
  Future<List<RankedHit>> searchBy(
    EmbeddingInput query, {
    Set<MultimodalRagKind>? kinds,
    Set<String> exclude = const {},
    int limit = 8,
    double minLift = kMinLift,
  }) async {
    final scores = <MultimodalRagKind, List<ScoredDocument>>{};
    var embedding = Duration.zero;
    for (final MapEntry(key: kind, value: index) in _indexes.entries) {
      if (kinds != null && !kinds.contains(kind)) continue;
      final count = _counts[kind] ?? 0;
      if (count == 0) continue;
      final hits = await index.search(query: query, topK: count);
      embedding += _embedders[kind]!.last ?? Duration.zero;
      scores[kind] = [
        for (final hit in hits)
          if (!exclude.contains(hit.id))
            (id: hit.id, similarity: hit.similarity),
      ];
    }
    lastQueryEmbedding = embedding;
    return rankAcrossKinds(scores, limit: limit, minLift: minLift);
  }

  /// Embeds [query] — a recording or a photo, NOT text — once, for
  /// [searchVector] and for storing elsewhere (Live's meeting index). A media
  /// query has one role whatever it is compared with (the RAG adapter sends
  /// it raw), so one vector serves every kind; text is embedded per kind,
  /// in its role, by [search].
  Future<List<double>> embedQuery(EmbeddingInput query) async {
    if (query.text != null) {
      throw ArgumentError.value(query, 'query', 'must not carry text');
    }
    final embedder = _embedders.values.first;
    final vector = await embedder.embedQuery(
      query,
      documentModality: EmbeddingModality.audio,
    );
    lastQueryEmbedding = embedder.last ?? Duration.zero;
    return vector;
  }

  /// [searchBy] with a vector from [embedQuery].
  Future<List<RankedHit>> searchVector(
    List<double> vector, {
    Set<MultimodalRagKind>? kinds,
    Set<String> exclude = const {},
    int limit = 8,
    double minLift = kMinLift,
  }) async {
    final scores = <MultimodalRagKind, List<ScoredDocument>>{};
    for (final MapEntry(key: kind, value: index) in _indexes.entries) {
      if (kinds != null && !kinds.contains(kind)) continue;
      final count = _counts[kind] ?? 0;
      if (count == 0) continue;
      final hits = await index.searchVector(embedding: vector, topK: count);
      scores[kind] = [
        for (final hit in hits)
          if (!exclude.contains(hit.id))
            (id: hit.id, similarity: hit.similarity),
      ];
    }
    return rankAcrossKinds(scores, limit: limit, minLift: minLift);
  }

  /// How long embedding the last query took, summed over the kinds searched
  /// (each index embeds it in its own role).
  Duration lastQueryEmbedding = Duration.zero;

  /// Empties [kind]'s index.
  Future<void> clearKind(MultimodalRagKind kind) async {
    final index = _require(kind);
    await index.clear();
    await index.flush();
    _counts[kind] = (await index.stats()).documentCount;
  }

  /// Empties every kind's index.
  Future<void> clear() async {
    for (final index in _indexes.values) {
      await index.clear();
      await index.flush();
    }
    await _refreshCounts();
  }

  /// Makes the writes durable (a no-op on native SQLite, a fence on the web).
  Future<void> flush() async {
    for (final index in _indexes.values) {
      await index.flush();
    }
  }

  /// Disposes the indexes. The embedder is borrowed and stays open.
  Future<void> dispose() async {
    for (final index in _indexes.values) {
      await index.dispose();
    }
  }

  Future<void> _refreshCounts() async {
    for (final MapEntry(key: kind, value: index) in _indexes.entries) {
      _counts[kind] = (await index.stats()).documentCount;
    }
  }

  RagIndex _require(MultimodalRagKind kind) =>
      _indexes[kind] ??
      (throw StateError('${kind.plural} are not indexed on this setup.'));
}

/// Times each embedding a RAG index asks for, so the screen can show what
/// one item cost without leaving the RAG API.
final class TimedRagEmbedder implements RagEmbedder {
  TimedRagEmbedder(this._inner);

  final RagEmbedder _inner;

  /// How long the last embedding took.
  Duration? last;

  @override
  Set<EmbeddingModality> get modalities => _inner.modalities;

  @override
  Future<EmbeddingProfile> resolveProfile() => _inner.resolveProfile();

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) =>
      _timed(() => _inner.embedDocument(document));

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) => _timed(
    () => _inner.embedQuery(query, documentModality: documentModality),
  );

  Future<List<double>> _timed(Future<List<double>> Function() embed) async {
    final watch = Stopwatch()..start();
    final vector = await embed();
    last = watch.elapsed;
    return vector;
  }
}
