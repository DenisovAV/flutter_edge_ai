import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// Stable identity and vector dimension for one embedding space.
///
/// A persistent vector-store location must contain vectors from exactly one
/// profile. [RagIndex] pins the profile at runtime and the vector-store
/// provider persists it beside the vectors so reopen cannot silently mix
/// embedding spaces.
class EmbeddingProfile {
  factory EmbeddingProfile({required String id, required int dimension}) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (dimension <= 0) {
      throw ArgumentError.value(
        dimension,
        'dimension',
        'must be greater than 0',
      );
    }
    return EmbeddingProfile._(id: id, dimension: dimension);
  }

  const EmbeddingProfile._({required this.id, required this.dimension});

  final String id;
  final int dimension;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmbeddingProfile &&
          other.id == id &&
          other.dimension == dimension;

  @override
  int get hashCode => Object.hash(id, dimension);

  @override
  String toString() => 'EmbeddingProfile(id: $id, dimension: $dimension)';
}

/// Embeds RAG documents and queries in one declared embedding space.
abstract interface class RagEmbedder {
  Future<EmbeddingProfile> get profile;

  Future<List<double>> embedDocument(String text);

  Future<List<double>> embedQuery(String text);
}

typedef ActiveEmbedderSpecResolver = EmbeddingModelSpec? Function();
typedef ActiveEmbeddingModelResolver = Future<EmbeddingModel> Function();

/// Borrowed adapter over Flutter Edge AI's active embedding model.
///
/// Resolution is lazy and single-flight. The first text operation snapshots
/// the active [EmbeddingModelSpec], borrows the core-owned singleton through
/// [FlutterEdgeAi.getActiveEmbedder], derives the actual vector dimension, and
/// pins that exact model/profile pair for this adapter's lifetime. This adapter
/// never closes the borrowed model.
///
/// [profileId] is deliberately explicit: a file path or download URL is not a
/// content identity because bytes at that location may change. Use an ID that
/// versions the weights and every embedding-space input that matters, such as
/// tokenizer, pooling, normalization, and document/query prefix contract.
class FlutterEdgeAiActiveEmbedder implements RagEmbedder {
  FlutterEdgeAiActiveEmbedder({
    required String profileId,
    PreferredBackend? preferredBackend,
    ActiveEmbedderSpecResolver? specResolver,
    ActiveEmbeddingModelResolver? modelResolver,
  }) : _profileId = _validateProfileId(profileId),
       _specResolver = specResolver ?? (() => FlutterEdgeAi.activeEmbedderSpec),
       _modelResolver =
           modelResolver ??
           (() => FlutterEdgeAi.getActiveEmbedder(
             preferredBackend: preferredBackend,
           )) {
    _expectedSpec = _specResolver();
  }

  final String _profileId;
  final ActiveEmbedderSpecResolver _specResolver;
  final ActiveEmbeddingModelResolver _modelResolver;
  late final EmbeddingModelSpec? _expectedSpec;
  Future<_ResolvedEmbedder>? _resolution;

  Future<_ResolvedEmbedder> _resolve() {
    final existing = _resolution;
    if (existing != null) return existing;

    late final Future<_ResolvedEmbedder> tracked;
    tracked = _resolveOnce().then(
      (resolved) => resolved,
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_resolution, tracked)) {
          _resolution = null;
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _resolution = tracked;
    return tracked;
  }

  Future<_ResolvedEmbedder> _resolveOnce() async {
    final expected = _expectedSpec;
    if (expected == null) {
      throw StateError(
        'No active embedding model was configured when the RAG index was '
        'opened. Install one first, or pass an explicit RagEmbedder.',
      );
    }

    final before = _specResolver();
    if (before != expected) {
      throw StateError(
        'The active embedding model changed after the RAG index was opened. '
        'Open a new RagIndex for the new embedding profile.',
      );
    }

    final model = await _modelResolver();
    final after = _specResolver();
    if (after != expected) {
      throw StateError(
        'The active embedding model changed while the RAG embedder was '
        'being resolved. Open a new RagIndex after model switching completes.',
      );
    }

    final dimension = await model.getDimension();
    final profile = EmbeddingProfile(id: _profileId, dimension: dimension);
    return _ResolvedEmbedder(model: model, profile: profile);
  }

  static String _validateProfileId(String profileId) {
    if (profileId.trim().isEmpty) {
      throw ArgumentError.value(profileId, 'profileId', 'must not be empty');
    }
    return profileId;
  }

  @override
  Future<EmbeddingProfile> get profile async => (await _resolve()).profile;

  @override
  Future<List<double>> embedDocument(String text) async => (await _resolve())
      .model
      .generateEmbedding(text, taskType: TaskType.retrievalDocument);

  @override
  Future<List<double>> embedQuery(String text) async => (await _resolve()).model
      .generateEmbedding(text, taskType: TaskType.retrievalQuery);
}

class _ResolvedEmbedder {
  const _ResolvedEmbedder({required this.model, required this.profile});

  final EmbeddingModel model;
  final EmbeddingProfile profile;
}
