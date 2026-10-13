import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'island_catalog.dart';
import 'island_decider.dart';
import 'island_scoring.dart';
import 'island_vector_cache.dart';

/// TEMPORARY stand-in for the core Decider (`EmbeddingModel.createDecider`,
/// being built on `feat/decision-engine`), over the public embedding API only:
/// every option's examples and description are embedded once (and cached per
/// model and catalog), a request is embedded and scored against all of them,
/// and an option's score is its best example's cosine similarity.
///
/// When the core API lands, this file is replaced by an adapter that maps
/// `Decider.choose(DeciderInput(EmbeddingInput.text(request)))` onto an
/// [IslandDecision]; nothing else in the screen changes.
///
/// Calibration (EmbeddingGemma 2 270M, macOS CPU, `TaskType.sentenceSimilarity`
/// on both sides, 184 options / 920 texts): 37 of 38 held-out requests ranked
/// right (English, Russian, German, French); their best score was 0.919 at the
/// lowest, while 13 of 14 unrelated requests ("what is the capital of France")
/// stayed at or under 0.896 — the 14th was "hello", which chose `wave`. Hence
/// [threshold] 0.915. Margins between near-twins are small ("close the lid of
/// the chest": close 0.979, open 0.968), so ambiguity abstains only on a
/// near-tie.
final class EmbeddingIslandDecider implements IslandDecider {
  EmbeddingIslandDecider._(
    this._model,
    this.name,
    this._owners,
    this._vectors,
    this._dimension,
    this._closeModel,
    this.threshold,
    this.minMargin,
  );

  /// Embeds [catalog] with [model] (or reads the vectors [cache] kept for
  /// [profileId] and this exact catalog), reporting [onProgress] as texts are
  /// embedded. Throws what the embedder throws; [isCancelled] stops it with a
  /// [StateError] between batches.
  static Future<EmbeddingIslandDecider> create({
    required EmbeddingModel model,
    required String name,
    required String profileId,
    required List<IslandAction> catalog,
    required IslandVectorCache cache,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    bool closeModel = true,
    double threshold = 0.915,
    double minMargin = 0.002,
  }) async {
    final owners = <String>[];
    final texts = <String>[];
    for (final action in catalog) {
      for (final text in [...action.examples, action.description]) {
        owners.add(action.id);
        texts.add(text);
      }
    }
    final dimension = model.dimension;
    // Everything that changes the vectors is in the key: the embedding space,
    // the task prefix, the texts, and this format.
    final key =
        'v1_${_safe(profileId)}_${_taskType.name}_${_fnv1a(texts)}_'
        '${texts.length}';
    var vectors = await cache.read(key);
    if (vectors == null || vectors.length != texts.length * dimension) {
      vectors = Float32List(texts.length * dimension);
      const batch = 16;
      for (var start = 0; start < texts.length; start += batch) {
        if (isCancelled?.call() ?? false) {
          throw StateError('Preparing the Decider was cancelled.');
        }
        final end = math.min(start + batch, texts.length);
        final embedded = await model.embedAll([
          for (var i = start; i < end; i++) EmbeddingInput.text(texts[i]),
        ], taskType: _taskType);
        for (var i = start; i < end; i++) {
          _writeNormalized(vectors, i * dimension, embedded[i - start]);
        }
        onProgress?.call(end, texts.length);
      }
      try {
        await cache.write(key, vectors);
      } catch (e, st) {
        // The vectors are in memory either way: this visit decides the same.
        // Only the next visit pays for embedding them again.
        debugPrint('[TinyIsland] could not cache the option vectors: $e\n$st');
      }
    } else {
      onProgress?.call(texts.length, texts.length);
    }
    return EmbeddingIslandDecider._(
      model,
      name,
      owners,
      vectors,
      dimension,
      closeModel,
      threshold,
      minMargin,
    );
  }

  /// Symmetric phrase-to-phrase similarity: requests and examples are the
  /// same kind of text.
  static const _taskType = TaskType.sentenceSimilarity;

  final EmbeddingModel _model;
  final List<String> _owners;
  final Float32List _vectors;
  final int _dimension;
  final bool _closeModel;
  final double threshold;
  final double minMargin;

  @override
  final String name;

  @override
  String? get backend => _model.activeBackend?.name;

  @override
  int get optionCount => _owners.toSet().length;

  @override
  Future<IslandDecision> decide(String request) async {
    final embedWatch = Stopwatch()..start();
    final query = await _model.embed(
      EmbeddingInput.text(request),
      taskType: _taskType,
    );
    embedWatch.stop();
    final scoreWatch = Stopwatch()..start();
    final q = Float32List(_dimension);
    _writeNormalized(q, 0, query);
    final scores = <String, double>{};
    for (var row = 0; row < _owners.length; row++) {
      final base = row * _dimension;
      var dot = 0.0;
      for (var i = 0; i < _dimension; i++) {
        dot += q[i] * _vectors[base + i];
      }
      final id = _owners[row];
      if (dot > (scores[id] ?? double.negativeInfinity)) scores[id] = dot;
    }
    scoreWatch.stop();
    return rankIslandOptions(
      scores: scores,
      threshold: threshold,
      minMargin: minMargin,
      temperature: 0.01,
      embedTime: embedWatch.elapsed,
      scoreTime: scoreWatch.elapsed,
    );
  }

  @override
  Future<void> close() async {
    if (_closeModel) await _model.close();
  }

  static void _writeNormalized(Float32List out, int at, List<double> v) {
    var norm = 0.0;
    for (final x in v) {
      norm += x * x;
    }
    norm = math.sqrt(norm);
    if (norm == 0) throw StateError('The embedder returned a zero vector.');
    for (var i = 0; i < v.length; i++) {
      out[at + i] = v[i] / norm;
    }
  }

  /// 32-bit FNV-1a over every text: the cache key changes when the catalog
  /// does.
  static String _fnv1a(List<String> texts) {
    var hash = 0x811c9dc5;
    for (final text in texts) {
      for (final byte in [...utf8.encode(text), 0]) {
        hash ^= byte;
        // hash * 0x01000193 mod 2^32 in 16-bit halves: exact on the web too,
        // where a full product would pass 2^53.
        final lo = hash & 0xffff;
        final hi = hash >> 16;
        hash =
            (lo * 0x0193 + (((hi * 0x0193 + lo * 0x0100) & 0xffff) << 16)) &
            0xffffffff;
      }
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _safe(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
