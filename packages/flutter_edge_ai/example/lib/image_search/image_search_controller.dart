import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import '../models/embedding_model.dart' show imageIndexProfileId;
import 'eg2_vision_samples.dart';
import 'photo_preparation.dart';
import 'photo_store.dart';

/// One encoded image the user picked (or a bundled sample).
typedef PickedPhoto = ({String name, Uint8List bytes});

/// A photo the user picked, not read yet: [read] loads its encoded bytes.
/// Lets a batch hold one original in memory at a time.
typedef PickedPhotoSource = ({String name, Future<Uint8List> Function() read});

/// Everything the Image Search screen needs from outside: the embedder, the
/// RAG index, where photos live, and where they come from. The app's wiring is
/// `imageSearchAppDependencies()`; tests pass fakes.
final class ImageSearchDependencies {
  const ImageSearchDependencies({
    required this.hasActiveEmbedder,
    required this.textProfileId,
    required this.loadEmbedder,
    required this.ragEmbedder,
    required this.openIndex,
    required this.photos,
    required this.pickPhotos,
    required this.pickQueryPhoto,
    required this.loadSample,
    this.prepare = preparePhotoForEmbedding,
    this.closeEmbedderOnDispose = true,
  });

  /// Whether an embedder is installed and active at all.
  final bool Function() hasActiveEmbedder;

  /// The active embedder's catalog profile id (its TEXT space), or null when
  /// it is not a catalog model.
  final Future<String?> Function() textProfileId;

  /// `FlutterEdgeAi.getActiveEmbedder(supportImage: true)`.
  final Future<EmbeddingModel> Function() loadEmbedder;

  /// The RAG adapter over the active embedder for an image index.
  final RagEmbedder Function(String imageProfileId) ragEmbedder;

  /// Opens (or reopens) the image index bound to [embedder]'s profile.
  final Future<RagIndex> Function(RagEmbedder embedder) openIndex;

  final PhotoStore photos;

  /// Photos to add, not read yet; empty when the user cancelled.
  final Future<List<PickedPhotoSource>> Function() pickPhotos;

  /// A photo to search by; null when the user cancelled.
  final Future<PickedPhoto?> Function() pickQueryPhoto;

  /// The bytes of a bundled asset.
  final Future<Uint8List> Function(String assetKey) loadSample;

  /// Turns an encoded photo into what the model gets: upright (EXIF applied)
  /// and at most 1024 px on its long side. Throws [PhotoDecodeException] for
  /// bytes this platform cannot decode.
  final Future<PreparedPhoto> Function(Uint8List encoded) prepare;

  /// Close the embedder when the screen goes: the vision tower holds about
  /// 385 MB once it has embedded an image.
  final bool closeEmbedderOnDispose;
}

enum ImageSearchStatus { loading, ready, failed }

/// A hit: the photo's reference, its cosine similarity, and a label.
typedef ImageSearchHit = ({String reference, double score, String label});

/// A photo indexed in this session, with what embedding it cost.
typedef IndexedPhoto = ({String reference, String label, Duration embed});

/// The Image Search screen's state and operations: text → image and image →
/// image search over a RAG image index, on the active EmbeddingGemma 2 bundle
/// with a vision encoder.
///
/// Every failure is kept in [error] (or, per photo while adding, in
/// [addFailures]) for the screen to show — never swallowed.
final class ImageSearchController extends ChangeNotifier {
  ImageSearchController(this._deps);

  final ImageSearchDependencies _deps;
  _TimedRagEmbedder? _embedder;
  RagIndex? _index;
  EmbeddingModel? _model;
  bool _disposed = false;

  ImageSearchStatus status = ImageSearchStatus.loading;

  /// What failed last, ready to show; null when nothing did.
  String? error;

  /// True when [error] is fixed by choosing another model on the list.
  bool suggestModelList = false;

  /// An operation is running.
  bool busy = false;

  /// What [busy] is doing, e.g. "Embedding 3 of 10".
  String? progress;

  PreferredBackend? activeBackend;
  Duration? loadTime;
  int? dimension;
  Set<EmbeddingModality> modalities = const {};
  String? profileId;
  int documentCount = 0;

  /// Photos indexed in this session, newest first.
  final List<IndexedPhoto> added = [];

  /// Photos that could not be added in the last batch, with the reason.
  final List<String> addFailures = [];

  List<ImageSearchHit> results = const [];

  /// What [results] answer: the query text, or the query photo's name.
  String? resultsFor;

  /// How long embedding the last query took.
  Duration? queryEmbed;

  /// The median embedding time of [added].
  Duration? get medianEmbed {
    if (added.isEmpty) return null;
    final times = [for (final photo in added) photo.embed]..sort();
    return times[times.length ~/ 2];
  }

  /// Loads the embedder with images declared and opens the image index.
  /// Called again after the user chose another model.
  Future<void> open() async {
    _set(() {
      status = ImageSearchStatus.loading;
      error = null;
      suggestModelList = false;
    });
    final previous = _index;
    _index = null;
    _embedder = null;
    try {
      await previous?.dispose();
      if (!_deps.hasActiveEmbedder()) {
        throw const _Refusal(
          'No embedding model is active. Choose EmbeddingGemma 2 Text + '
          'Vision (440M) on the Embedding Models list, then come back.',
        );
      }
      final textId = await _deps.textProfileId();
      if (textId == null) {
        throw const _Refusal(
          'The active embedding model is not from the example catalog, so this '
          'screen cannot name its embedding space. Choose EmbeddingGemma 2 '
          'Text + Vision (440M) on the Embedding Models list.',
        );
      }
      final watch = Stopwatch()..start();
      // Throws EmbeddingLoadException when the model has no vision encoder
      // (the 270M names the 440M bundle) or is not EmbeddingGemma 2 at all.
      final model = await _deps.loadEmbedder();
      watch.stop();
      if (_disposed) {
        // The screen went while the model loaded: nobody else will close it.
        if (_deps.closeEmbedderOnDispose) await model.close();
        return;
      }
      _model = model;
      final id = imageIndexProfileId(textId);
      final embedder = _TimedRagEmbedder(_deps.ragEmbedder(id));
      final index = await _deps.openIndex(embedder);
      if (_disposed) {
        await index.dispose();
        return;
      }
      _embedder = embedder;
      _index = index;
      final stats = await index.stats();
      _set(() {
        loadTime = watch.elapsed;
        activeBackend = model.activeBackend;
        dimension = model.dimension;
        modalities = model.modalities;
        profileId = id;
        documentCount = stats.documentCount;
        status = ImageSearchStatus.ready;
      });
      debugPrint(
        '[ImageSearch] ready: backend=${model.activeBackend}, load '
        '${watch.elapsedMilliseconds} ms, profile $id, '
        '${stats.documentCount} photos indexed',
      );
    } catch (e, st) {
      debugPrint('[ImageSearch] open failed: $e\n$st');
      _set(() {
        status = ImageSearchStatus.failed;
        error = _describe(e);
        suggestModelList =
            e is _Refusal || e is EmbeddingLoadException || e is StateError;
      });
    }
  }

  /// Adds the ten bundled scenes (replacing them if they were added before).
  /// They are referenced by asset key, so nothing is copied.
  Future<void> addSamples() => _run(
    'Adding samples',
    () => _add([
      for (final scene in eg2VisionSampleCaptions.keys)
        (
          id: 'sample-$scene',
          name: '$scene.png',
          read: () => _deps.loadSample(eg2VisionSampleAsset(scene)),
          asset: assetPhotoReference(eg2VisionSampleAsset(scene)),
        ),
    ]),
  );

  /// Lets the user pick photos and adds each.
  Future<void> addPhotos() => _run('Adding photos', () async {
    final picked = await _deps.pickPhotos();
    // The screen may have gone while the picker was open: copy nothing.
    if (picked.isEmpty || _disposed || _index == null) return;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await _add([
      for (final (i, photo) in picked.indexed)
        (
          id: 'photo-$stamp-$i',
          name: photo.name,
          read: photo.read,
          asset: null,
        ),
    ]);
  });

  /// Adds [photos] one at a time: read the original, prepare it (upright, at
  /// most 1024 px), copy the original (unless it is an asset), embed and store
  /// it, then let its bytes go before the next is read — a batch of full-size
  /// photos never sits in memory at once.
  ///
  /// A photo this platform cannot decode, or the model refuses, is listed in
  /// [addFailures] and the rest are still added. Any other failure stops the
  /// batch and is shown by [_run]. Either way the copy the failed photo got
  /// is deleted; the copies of photos already added stay, because the index
  /// refers to them.
  Future<void> _add(List<_PendingPhoto> photos) async {
    addFailures.clear();
    for (var i = 0; i < photos.length; i++) {
      final photo = photos[i];
      // Checked before every read and copy: the screen may have gone.
      final index = _index;
      final embedder = _embedder;
      if (_disposed || index == null || embedder == null) return;
      _set(() => progress = 'Embedding ${i + 1} of ${photos.length}');
      final bytes = await photo.read();
      if (_disposed) return;
      String? copy;
      try {
        // Upright and at most 1024 px: the engine ignores EXIF orientation
        // and would decode a camera original at full size.
        final prepared = await _deps.prepare(bytes);
        if (_disposed) return;
        // The original is what is kept and shown; the model gets the
        // prepared pixels.
        final reference =
            photo.asset ??
            (copy = await _deps.photos.keep(bytes, name: photo.name));
        await index.add(
          id: photo.id,
          document: EmbeddingInput.image(prepared.bytes),
          content: reference,
        );
        copy = null; // indexed: the copy belongs to the index now
        added.insert(0, (
          reference: reference,
          label: photo.name,
          embed: embedder.last ?? Duration.zero,
        ));
      } on PhotoDecodeException catch (e) {
        debugPrint('[ImageSearch] ${photo.name} not added: $e');
        addFailures.add(
          '${photo.name}: could not decode it on this platform (${e.message})',
        );
      } on EmbeddingException catch (e) {
        debugPrint('[ImageSearch] ${photo.name} not added: $e');
        addFailures.add('${photo.name}: ${e.message}');
      } finally {
        if (copy != null) await _forget(copy);
      }
    }
    final index = _requireIndex();
    await index.flush();
    documentCount = (await index.stats()).documentCount;
  }

  /// Deletes a copy that was never indexed. A failure here is logged: the
  /// error the user sees is the one that stopped the photo.
  Future<void> _forget(String copy) async {
    try {
      await _deps.photos.forget(copy);
    } catch (e, st) {
      debugPrint('[ImageSearch] could not delete $copy: $e\n$st');
    }
  }

  /// Text → image: the photos that best match [query].
  Future<void> searchText(String query) {
    final text = query.trim();
    if (text.isEmpty) return Future.value();
    return _run('Searching', () async {
      final hits = await _requireIndex().search(
        query: EmbeddingInput.text(text),
        topK: 10,
      );
      _show(hits, '"$text"');
    });
  }

  /// Image → image: lets the user pick a photo and finds the closest ones.
  Future<void> searchByPhoto() => _run('Searching', () async {
    final photo = await _deps.pickQueryPhoto();
    if (photo == null) return;
    await _searchByImage(photo);
  });

  /// Image → image with [photo] as the query.
  Future<void> searchByImage(PickedPhoto photo) =>
      _run('Searching', () => _searchByImage(photo));

  Future<void> _searchByImage(PickedPhoto photo) async {
    final prepared = await _deps.prepare(photo.bytes);
    final hits = await _requireIndex().search(
      query: EmbeddingInput.image(prepared.bytes),
      topK: 10,
    );
    _show(hits, photo.name);
  }

  void _show(List<RetrievalResult> hits, String query) {
    results = [
      for (final hit in hits)
        (
          reference: hit.content,
          score: hit.similarity,
          label: photoLabel(hit.content),
        ),
    ];
    resultsFor = query;
    queryEmbed = _embedder?.last;
  }

  /// Empties the index and deletes the photos it kept.
  Future<void> clearIndex() => _run('Clearing', () async {
    final index = _requireIndex();
    await index.clear();
    await index.flush();
    await _deps.photos.forgetAll();
    added.clear();
    addFailures.clear();
    results = const [];
    resultsFor = null;
    documentCount = 0;
  });

  RagIndex _requireIndex() =>
      _index ?? (throw StateError('The image index is not open.'));

  Future<void> _run(String what, Future<void> Function() body) async {
    if (busy) return;
    _set(() {
      busy = true;
      progress = what;
      error = null;
    });
    try {
      await body();
    } catch (e, st) {
      debugPrint('[ImageSearch] $what failed: $e\n$st');
      error = _describe(e);
    } finally {
      _set(() {
        busy = false;
        progress = null;
      });
    }
  }

  static String _describe(Object error) => switch (error) {
    _Refusal(:final message) => message,
    PhotoDecodeException(:final message) =>
      'Could not decode that photo on this platform ($message).',
    EmbeddingException(:final message) => message,
    StateError(:final message) => message,
    ArgumentError(:final message) => '$message',
    _ => '$error',
  };

  void _set(void Function() change) {
    change();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final index = _index;
    final model = _deps.closeEmbedderOnDispose ? _model : null;
    _index = null;
    _model = null;
    // dispose() cannot await. The index waits for accepted operations before
    // it closes its store; only then is the borrowed embedder closed.
    unawaited(
      () async {
        await index?.dispose();
        await model?.close();
      }().catchError((Object e, StackTrace st) {
        debugPrint('[ImageSearch] closing failed: $e\n$st');
      }),
    );
    super.dispose();
  }
}

/// A photo on its way into the index: [read] loads its encoded bytes; an
/// [asset] reference means it is not copied.
typedef _PendingPhoto = ({
  String id,
  String name,
  Future<Uint8List> Function() read,
  String? asset,
});

/// A refusal of this screen's own, with a message ready to show.
final class _Refusal implements Exception {
  const _Refusal(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Times each embedding the index asks for, so the screen can show what one
/// image costs without leaving the RAG API.
final class _TimedRagEmbedder implements RagEmbedder {
  _TimedRagEmbedder(this._inner);

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
