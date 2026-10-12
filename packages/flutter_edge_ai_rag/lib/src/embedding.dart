import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'active_model_profile_id.dart';
import 'profile_id.dart';

/// Stable identity and vector dimension for one embedding space.
///
/// A persistent vector-store location must contain vectors from exactly one
/// profile. [RagIndex] pins the profile at open and the vector-store provider
/// persists it beside the vectors (as part of a `VectorStoreBinding`), so a
/// reopen cannot silently mix embedding spaces.
final class EmbeddingProfile {
  /// [id] must not be empty and must not contain control characters
  /// (U+0000–U+001F; U+001F is reserved for the storage qualifier of image and
  /// audio bindings). [dimension] must be greater than 0. Throws
  /// [ArgumentError] otherwise.
  factory EmbeddingProfile({required String id, required int dimension}) {
    checkProfileIdText(id, 'id');
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
///
/// Apps implement this for their own embedding pipelines. The member set is
/// fixed. There is no batch member: the native batch API brought no gain, so
/// none is planned.
///
/// The embedder, not RAG, maps a role (document or query) to its model's
/// conventions — task prefixes, which task a text query over image documents
/// uses, MRL truncation — so RAG stays model-agnostic.
abstract interface class RagEmbedder {
  /// The embedding space this embedder produces vectors in. Loads the model
  /// if needed, which is why it is a method and not a getter.
  Future<EmbeddingProfile> resolveProfile();

  /// The modalities this embedder can embed, as documents and as queries.
  Set<EmbeddingModality> get modalities;

  /// Embeds one document to be stored.
  Future<List<double>> embedDocument(EmbeddingInput document);

  /// Embeds one query that is compared against documents of
  /// [documentModality].
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  });
}

typedef ActiveEmbedderSpecResolver = EmbeddingModelSpec? Function();
typedef ActiveEmbeddingModelResolver = Future<EmbeddingModel> Function();

/// Borrowed adapter over Flutter Edge AI's active embedding model.
///
/// It pins the ACTIVE [EmbeddingModelSpec] when it is constructed and then
/// resolves the model per operation through [FlutterEdgeAi.getActiveEmbedder]
/// (a cache hit there is a map compare). Resolving per operation is what lets
/// a text index and an image index share one model: when the image index asks
/// for `supportImage`, core rebuilds the embedder with both, and the text
/// index simply picks up the new model on its next operation.
///
/// A request that fails with [EmbedderClosedException] never ran — the model
/// was closed before it started, typically because core replaced it — so the
/// adapter resolves the model again and retries it once.
///
/// Any operation throws [StateError] when the active spec differs from the
/// one pinned at construction: open a new index for a new model. This adapter
/// never closes the model it borrows; dispose indexes before closing the
/// embedder or calling `FlutterEdgeAi.dispose()`.
///
/// `profileId` is deliberately explicit: a file path or download URL is not a
/// content identity because bytes at that location may change. Use an ID that
/// versions the weights and every embedding-space input that matters, such as
/// tokenizer, pooling, normalization, and document/query prefix contract. Or
/// derive one from the installed files with
/// [FlutterEdgeAiActiveEmbedder.forActiveModel].
///
/// Role → task policy: documents embed with [TaskType.retrievalDocument]
/// (the prefix reaches text parts only); a text query over text documents
/// uses `queryTask`; a text query over image or audio documents uses
/// [TaskType.none]; a media query uses [TaskType.none] (a prefix never reaches
/// media).
final class FlutterEdgeAiActiveEmbedder implements RagEmbedder {
  /// Throws [ArgumentError] when [profileId] is empty or contains a control
  /// character (the [EmbeddingProfile] id rules).
  FlutterEdgeAiActiveEmbedder({
    required String profileId,
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    bool supportAudio = false,
    TaskType queryTask = TaskType.retrievalQuery,
    @visibleForTesting ActiveEmbedderSpecResolver? specResolver,
    @visibleForTesting ActiveEmbeddingModelResolver? modelResolver,
  }) : this._(
         profileId: _validateProfileId(profileId),
         preferredBackend: preferredBackend,
         supportImage: supportImage,
         supportAudio: supportAudio,
         queryTask: queryTask,
         specResolver: specResolver ?? _activeSpec,
         modelResolver: modelResolver,
       );

  /// An adapter whose profile id is derived from the installed files of the
  /// active embedder: `'<namespace>@<installed file names joined by +>'`.
  ///
  /// Different namespaces or file lists always give different ids: `%`, `@`,
  /// `+` and U+0000–U+001F in the namespace and the file names are
  /// percent-encoded (`%25`, `%40`, `%2B`, `%XX`). Names without those
  /// characters appear as they are, so their ids read exactly as above.
  ///
  /// Installing a model under different file names therefore changes the id,
  /// and a store bound to the old one refuses to open — EmbeddingGemma 1 and
  /// 2 are both 768-dimensional, so the id is the only guard against mixing
  /// them. The id follows file NAMES, not bytes: install with
  /// revision-qualified file names (`filename:` on the install builder) so
  /// new weights under the same download name get a new id too.
  ///
  /// The id is deliberately stricter than a shared text id: two bundles that
  /// produce identical text vectors still get different ids here. An app
  /// that wants one store across such bundles passes an explicit
  /// `profileId` to the unnamed constructor instead. Existing explicit ids
  /// are never re-keyed.
  ///
  /// Throws [StateError] when no embedding model is active, and
  /// [ArgumentError] when [namespace] is empty or blank.
  factory FlutterEdgeAiActiveEmbedder.forActiveModel({
    required String namespace,
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    bool supportAudio = false,
    TaskType queryTask = TaskType.retrievalQuery,
  }) {
    if (namespace.trim().isEmpty) {
      throw ArgumentError.value(namespace, 'namespace', 'must not be empty');
    }
    final spec = _activeSpec();
    if (spec == null) {
      throw StateError(
        'FlutterEdgeAiActiveEmbedder.forActiveModel needs an active embedding '
        'model: install one with FlutterEdgeAi.installEmbedder() first.',
      );
    }
    return FlutterEdgeAiActiveEmbedder._(
      profileId: activeModelProfileId(namespace: namespace, spec: spec),
      preferredBackend: preferredBackend,
      supportImage: supportImage,
      supportAudio: supportAudio,
      queryTask: queryTask,
      specResolver: _activeSpec,
      expectedSpec: spec,
    );
  }

  FlutterEdgeAiActiveEmbedder._({
    required this._profileId,
    required PreferredBackend? preferredBackend,
    required bool supportImage,
    required bool supportAudio,
    required this._queryTask,
    required ActiveEmbedderSpecResolver specResolver,
    ActiveEmbeddingModelResolver? modelResolver,
    EmbeddingModelSpec? expectedSpec,
  }) : _specResolver = specResolver,
       _modelResolver =
           modelResolver ??
           (() => FlutterEdgeAi.getActiveEmbedder(
             preferredBackend: preferredBackend,
             supportImage: supportImage,
             supportAudio: supportAudio,
           )),
       _modalities = Set.unmodifiable({
         EmbeddingModality.text,
         if (supportImage) EmbeddingModality.image,
         if (supportAudio) EmbeddingModality.audio,
       }),
       _expectedSpec = expectedSpec ?? specResolver();

  final String _profileId;
  final TaskType _queryTask;
  final ActiveEmbedderSpecResolver _specResolver;
  final ActiveEmbeddingModelResolver _modelResolver;
  final Set<EmbeddingModality> _modalities;
  final EmbeddingModelSpec? _expectedSpec;

  static EmbeddingModelSpec? _activeSpec() => FlutterEdgeAi.activeEmbedderSpec;

  static String _validateProfileId(String profileId) {
    checkProfileIdText(profileId, 'profileId');
    return profileId;
  }

  /// Text, plus the media declared at construction (`supportImage`,
  /// `supportAudio`). A declared medium the installed model cannot embed
  /// fails when the model loads, in [resolveProfile].
  @override
  Set<EmbeddingModality> get modalities => _modalities;

  @override
  Future<EmbeddingProfile> resolveProfile() async {
    final model = await _resolveModel();
    return EmbeddingProfile(id: _profileId, dimension: model.dimension);
  }

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) =>
      _embed(document, TaskType.retrievalDocument);

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) => _embed(query, _queryTaskFor(query, documentModality));

  TaskType _queryTaskFor(EmbeddingInput query, EmbeddingModality documents) {
    final modalities = query.modalities;
    final textOnly =
        modalities.length == 1 && modalities.contains(EmbeddingModality.text);
    if (!textOnly) return TaskType.none;
    return documents == EmbeddingModality.text ? _queryTask : TaskType.none;
  }

  Future<List<double>> _embed(EmbeddingInput input, TaskType taskType) async {
    final model = await _resolveModel();
    try {
      return await model.embed(input, taskType: taskType);
    } on EmbedderClosedException {
      // The request never ran: the model was closed before it started, which
      // is what happens when core replaces the cached embedder (another index
      // asked for more media). Resolve the replacement and retry, once.
      final replacement = await _resolveModel();
      return replacement.embed(input, taskType: taskType);
    }
  }

  Future<EmbeddingModel> _resolveModel() async {
    final expected = _expectedSpec;
    if (expected == null) {
      throw StateError(
        'No active embedding model was configured when this '
        'FlutterEdgeAiActiveEmbedder was created. Install one first, then '
        'create the embedder, or pass your own RagEmbedder.',
      );
    }
    if (!_samePinnedModel(_specResolver(), expected)) {
      throw StateError(
        'The active embedding model changed after this '
        'FlutterEdgeAiActiveEmbedder was created. Open a new RagIndex, with a '
        'new embedder, for the new embedding profile.',
      );
    }
    final model = await _modelResolver();
    if (!_samePinnedModel(_specResolver(), expected)) {
      throw StateError(
        'The active embedding model changed while the RAG embedder was being '
        'resolved. Open a new RagIndex after model switching completes.',
      );
    }
    return model;
  }
}

/// Whether [active] is still the model a [FlutterEdgeAiActiveEmbedder] was
/// pinned to ([pinned]).
///
/// Not `==`: a spec's sources carry credentials and download options that are
/// not part of the model. A restart restores the active spec without the
/// download token (`ModelSource.encode` drops it) while the app's next
/// install passes it again, and the native shell restores the spec with
/// `FileSource`s at the installed files. What identifies the loaded model is
/// its installed files: the same file names in the same order (which also
/// fixes whether it is a self-contained bundle) and, where both specs name
/// the same kind of source, the same location — URL, asset, bundle or path —
/// ignoring tokens and download options.
bool _samePinnedModel(EmbeddingModelSpec? active, EmbeddingModelSpec pinned) {
  if (active == null) return false;
  if (active == pinned) return true;
  final activeFiles = active.files;
  final pinnedFiles = pinned.files;
  if (activeFiles.length != pinnedFiles.length) return false;
  for (var i = 0; i < activeFiles.length; i++) {
    if (activeFiles[i].filename != pinnedFiles[i].filename) return false;
    if (!_sameLocation(activeFiles[i].source, pinnedFiles[i].source)) {
      return false;
    }
  }
  return true;
}

/// Same-kind sources must name the same location; sources of different
/// kinds (a restore pointing at the installed file, an install from the
/// network) leave the decision to the file name.
bool _sameLocation(ModelSource a, ModelSource b) => switch ((a, b)) {
  (NetworkSource(url: final x), NetworkSource(url: final y)) => x == y,
  (AssetSource(path: final x), AssetSource(path: final y)) => x == y,
  (
    BundledSource(resourceName: final x),
    BundledSource(resourceName: final y),
  ) =>
    x == y,
  (FileSource(path: final x), FileSource(path: final y)) => x == y,
  _ => true,
};
