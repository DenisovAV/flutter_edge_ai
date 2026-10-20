// The Image Search screen over a FAKE embedder and an in-memory vector store,
// with the real flutter_edge_ai_rag in between (RagIndex, the image binding,
// and FlutterEdgeAiActiveEmbedder's role policy): adding photos, text → image
// and image → image search, and the failures it must show — the 270M's
// "no vision encoder" with a way to the model list, a photo the model cannot
// decode, and no active embedder. The real model runs in
// integration_test/embeddinggemma2_test.dart.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/image_search/eg2_vision_samples.dart';
import 'package:flutter_edge_ai_example/image_search/image_search_controller.dart';
import 'package:flutter_edge_ai_example/image_search/photo_preparation.dart';
import 'package:flutter_edge_ai_example/image_search/photo_store.dart';
import 'package:flutter_edge_ai_example/image_search_screen.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

const _textId = 'embeddinggemma2-litertlm-text-4410a540ce75-prefix-v1';

/// What the fake `prepare` appends, so the fake model can tell prepared bytes
/// from an original.
const _prepared = [0xEE, 0x50, 0x52, 0x45, 0x50];

bool _isPrepared(Uint8List b) =>
    b.length > _prepared.length &&
    [
          for (var i = 0; i < _prepared.length; i++)
            b[b.length - _prepared.length + i],
        ].join(',') ==
        _prepared.join(',');
final _scenes = eg2VisionSampleCaptions.keys.toList();

Uint8List _asset(String key) => File(key).readAsBytesSync();

void main() {
  late _FakeEmbedder model;
  late _Rig rig;

  setUp(() {
    final log = <String>[];
    model = _FakeEmbedder(log);
    rig = _Rig(model, log);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    // Tall enough that the whole list is built (it is lazy).
    tester.view
      ..physicalSize = const Size(1200, 4000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ImageSearchScreen(
          dependencies: rig.dependencies(),
          onChooseModel: (_) async => rig.choseModel++,
        ),
      ),
    );
    await settle(tester);
  }

  String textOf(WidgetTester tester, Key key) =>
      tester.widget<Text>(find.byKey(key)).data!;

  testWidgets('adds the samples, then finds a photo by text and by photo, '
      'with scores, the backend, load and embed times', (tester) async {
    await pumpScreen(tester);
    final card = find.byKey(const Key('image-search-model'));
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('Backend: cpu · loaded in'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('text + image')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.textContaining('Profile: $_textId-vis140'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('218 MB vision cache'), findsOneWidget);
    expect(rig.loads, 1);
    expect(model.declaredImages, isTrue);

    await tester.tap(find.byKey(const Key('image-search-add-samples')));
    await settle(tester);
    expect(
      textOf(tester, const Key('image-search-count')),
      '10 photos in the index',
    );
    expect(
      find.descendant(of: card, matching: find.textContaining('Per image:')),
      findsOneWidget,
    );
    expect(rig.store.binding?.documents, EmbeddingModality.image);
    expect(rig.store.binding?.profile.id, '$_textId-vis140');
    expect(model.tasks.toSet(), {
      TaskType.retrievalDocument,
    }, reason: 'documents embed with the document role');
    expect(
      rig.store.contents,
      contains('asset:assets/eg2_vision/stop_sign.png'),
      reason: 'the index keeps a reference, never the bytes',
    );

    // Text → image.
    model.tasks.clear();
    await tester.enterText(
      find.byKey(const Key('image-search-query')),
      'a red stop sign',
    );
    await tester.tap(find.byKey(const Key('image-search-search-text')));
    await settle(tester);
    expect(textOf(tester, const Key('image-search-label-0')), 'stop_sign.png');
    expect(
      double.parse(textOf(tester, const Key('image-search-score-0'))),
      greaterThan(
        double.parse(textOf(tester, const Key('image-search-score-1'))),
      ),
    );
    expect(model.tasks, [
      TaskType.none,
    ], reason: 'a text query over images is raw (the rag role policy)');
    expect(find.textContaining('Closest to "a red stop sign"'), findsOneWidget);

    // Image → image: a resized JPEG of the pie chart finds the pie chart.
    model.tasks.clear();
    rig.queryPhoto = (
      name: 'pie_chart_dup.jpg',
      bytes: _asset(eg2VisionDuplicateAsset('pie_chart')),
    );
    await tester.tap(find.byKey(const Key('image-search-search-photo')));
    await settle(tester);
    expect(textOf(tester, const Key('image-search-label-0')), 'pie_chart.png');
    expect(model.tasks, [TaskType.none]);
    expect(
      rig.log.last,
      'embed pie_chart',
      reason: 'the query photo is prepared too, not sent as the original',
    );
    expect(find.textContaining('Closest to pie_chart_dup.jpg'), findsOneWidget);
    expect(find.byKey(const Key('image-search-error')), findsNothing);
  });

  testWidgets('the 270M is refused with the reason and a way to the model '
      'list; choosing a model loads again', (tester) async {
    rig.loadError = const EmbeddingLoadException(
      'embeddinggemma-2-text-270m__rev-9be6e8b90982.litertlm has no vision '
      'encoder; install embeddinggemma-2-text-vision-440m',
      engine: 'LiteRT-LM',
    );
    await pumpScreen(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('image-search-error')),
        matching: find.textContaining(
          'has no vision encoder; install embeddinggemma-2-text-vision-440m',
        ),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('image-search-add-samples')), findsNothing);

    rig.loadError = null; // the user installed the 440M
    await tester.tap(find.byKey(const Key('image-search-choose-model')));
    await settle(tester);
    expect(rig.choseModel, 1);
    expect(rig.loads, 2);
    expect(find.byKey(const Key('image-search-error')), findsNothing);
    expect(find.byKey(const Key('image-search-add-samples')), findsOneWidget);
  });

  testWidgets('a photo the model cannot decode is refused with the reason, '
      'and the others are still added', (tester) async {
    await pumpScreen(tester);
    rig.picked = [
      rig.source('IMG_0001.HEIC', 'assets/eg2_vision/small_circle.heic'),
      rig.source('circle.png', eg2VisionSampleAsset('circle')),
    ];
    await tester.tap(find.byKey(const Key('image-search-add-photos')));
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('image-search-add-failures')),
        matching: find.textContaining(
          'IMG_0001.HEIC: could not decode it on this platform',
        ),
      ),
      findsOneWidget,
    );
    expect(
      textOf(tester, const Key('image-search-count')),
      '1 photo in the index',
    );
    expect(rig.photos.kept, hasLength(1), reason: 'the HEIC copy is deleted');
  });

  testWidgets('picked photos are streamed: each is read, copied and embedded '
      'before the next is read, so one original is in memory at a time', (
    tester,
  ) async {
    await pumpScreen(tester);
    rig.picked = [
      for (final scene in ['circle', 'square', 'triangle'])
        rig.source('$scene.png', eg2VisionSampleAsset(scene)),
    ];
    rig.log.clear();
    await tester.tap(find.byKey(const Key('image-search-add-photos')));
    await settle(tester);
    expect(rig.log, [
      for (final scene in ['circle', 'square', 'triangle']) ...[
        'read $scene.png',
        'prepare $scene',
        'keep $scene.png',
        'embed $scene',
      ],
    ]);
    expect(
      textOf(tester, const Key('image-search-count')),
      '3 photos in the index',
    );
    expect(
      rig.photos.kept.values.where(_isPrepared),
      isEmpty,
      reason: 'the original is what is kept and shown',
    );
  });

  testWidgets('thumbnails are decoded at their display size, not the '
      'original\'s', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const Key('image-search-add-samples')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const Key('image-search-query')),
      'a red stop sign',
    );
    await tester.tap(find.byKey(const Key('image-search-search-text')));
    await settle(tester);

    ImageProvider thumbnailOf(Finder parent) => tester
        .widget<Image>(
          find.descendant(of: parent, matching: find.byType(Image)).first,
        )
        .image;

    final hit = thumbnailOf(find.byKey(const Key('image-search-hit-0')));
    expect(hit, isA<ResizeImage>());
    // 104 logical px at 2x (the test view's ratio is 1).
    expect((hit as ResizeImage).width, 208);
    expect(hit.height, 208);
    expect(hit.policy, ResizeImagePolicy.fit);

    final strip = thumbnailOf(find.byKey(const Key('image-search-added')));
    expect(strip, isA<ResizeImage>());
    expect((strip as ResizeImage).width, 128);
  });

  testWidgets('closing the screen while the picker is open copies nothing', (
    tester,
  ) async {
    await pumpScreen(tester);
    final picker = Completer<List<PickedPhotoSource>>();
    rig.pickFuture = picker.future;
    await tester.tap(find.byKey(const Key('image-search-add-photos')));
    await settle(tester);
    await tester.pumpWidget(const SizedBox()); // the screen goes
    rig.log.clear();
    picker.complete([rig.source('circle.png', eg2VisionSampleAsset('circle'))]);
    await settle(tester);
    expect(rig.photos.kept, isEmpty, reason: 'no orphaned copy');
    expect(rig.log, isEmpty, reason: 'nothing was even read');
  });

  testWidgets('a store failure while adding is shown, and the copy that '
      'photo got is deleted', (tester) async {
    await pumpScreen(tester);
    rig.store.failAdds = true;
    rig.picked = [rig.source('circle.png', eg2VisionSampleAsset('circle'))];
    await tester.tap(find.byKey(const Key('image-search-add-photos')));
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('image-search-error')),
        matching: find.textContaining('disk full'),
      ),
      findsOneWidget,
    );
    expect(rig.photos.kept, isEmpty, reason: 'no orphaned copy');
  });

  testWidgets('Clear also clears the list of photos that were not added', (
    tester,
  ) async {
    await pumpScreen(tester);
    rig.picked = [
      rig.source('IMG_0001.HEIC', 'assets/eg2_vision/small_circle.heic'),
      rig.source('circle.png', eg2VisionSampleAsset('circle')),
    ];
    await tester.tap(find.byKey(const Key('image-search-add-photos')));
    await settle(tester);
    expect(find.byKey(const Key('image-search-add-failures')), findsOneWidget);
    await tester.tap(find.byKey(const Key('image-search-clear')));
    await settle(tester);
    expect(find.byKey(const Key('image-search-add-failures')), findsNothing);
    expect(
      textOf(tester, const Key('image-search-count')),
      '0 photos in the index',
    );
  });

  testWidgets('no active embedder: says what to install', (tester) async {
    rig.active = false;
    await pumpScreen(tester);
    expect(find.textContaining('No embedding model is active'), findsOneWidget);
    expect(find.byKey(const Key('image-search-choose-model')), findsOneWidget);
    expect(rig.loads, 0);
  });
}

// ── Fakes ───────────────────────────────────────────────────────────────────

/// Everything the screen reaches, faked, around the real RAG API.
final class _Rig {
  _Rig(this.model, this.log);

  final _FakeEmbedder model;

  /// Reads, copies and embeds, in the order they happened.
  final List<String> log;
  final store = _MemoryStore();
  late final photos = _MemoryPhotos(log);
  bool active = true;
  EmbeddingLoadException? loadError;
  int loads = 0;
  int choseModel = 0;
  List<PickedPhotoSource> picked = const [];

  /// When set, the picker answers with this instead of [picked].
  Future<List<PickedPhotoSource>>? pickFuture;

  /// A picked photo that logs when it is read.
  PickedPhotoSource source(String name, String asset) => (
    name: name,
    read: () async {
      log.add('read $name');
      return _asset(asset);
    },
  );
  PickedPhoto? queryPhoto;

  late final _spec = EmbeddingModelSpec(
    name: 'eg2-440m',
    modelSource: ModelSource.file('/models/eg2-440m.litertlm'),
  );

  ImageSearchDependencies dependencies() => ImageSearchDependencies(
    hasActiveEmbedder: () => active,
    textProfileId: () async => _textId,
    loadEmbedder: () async {
      loads++;
      final error = loadError;
      if (error != null) throw error;
      model.declaredImages = true;
      return model;
    },
    ragEmbedder: (profileId) => FlutterEdgeAiActiveEmbedder(
      profileId: profileId,
      supportImage: true,
      specResolver: () => _spec,
      modelResolver: () async => model,
    ),
    openIndex: (embedder) =>
        FlutterEdgeAiRag(providers: [_MemoryProvider(store)]).open(
          spec: VectorStoreSpec(
            providerId: 'memory',
            location: 'images',
            documents: EmbeddingModality.image,
          ),
          embedder: embedder,
        ),
    photos: photos,
    pickPhotos: () => pickFuture ?? Future.value(picked),
    pickQueryPhoto: () async => queryPhoto,
    loadSample: (key) async => _asset(key),
    // What iOS and macOS do with a HEIC; everything else passes through
    // (the real decoder is tested in photo_preparation_test.dart).
    prepare: (bytes) async {
      if (sniffEncodedMediaFormat(bytes) == EncodedMediaFormat.heic) {
        throw const PhotoDecodeException('Invalid image data');
      }
      log.add('prepare ${model.sceneOf(bytes)}');
      return (
        bytes: Uint8List.fromList([...bytes, ..._prepared]),
        width: 640,
        height: 480,
        sourceWidth: 640,
        sourceHeight: 480,
      );
    },
    closeEmbedderOnDispose: false,
  );
}

/// One-hot vectors per scene: a sample or its near-duplicate maps to its
/// scene, a text to the scene its caption's first word names. Refuses what
/// core's facade refuses for EmbeddingGemma 2 (anything but JPEG, PNG, GIF,
/// BMP), with the same exception.
final class _FakeEmbedder extends EmbeddingModel {
  _FakeEmbedder(this._log);

  final List<String> _log;
  final tasks = <TaskType>[];
  bool declaredImages = false;
  bool _closed = false;

  late final Map<String, int> _byBytes = {
    for (final (i, scene) in _scenes.indexed) ...{
      _key(_asset(eg2VisionSampleAsset(scene))): i,
      _key(_asset(eg2VisionDuplicateAsset(scene))): i,
    },
  };

  static String _key(Uint8List bytes) => '${bytes.length}:${bytes.take(64)}';

  /// The scene [bytes] are (a sample or its near-duplicate), for the log.
  String? sceneOf(Uint8List bytes) => switch (_byBytes[_key(bytes)]) {
    final i? => _scenes[i],
    null => null,
  };

  @override
  int get dimension => _scenes.length;

  @override
  Set<EmbeddingModality> get modalities => {
    EmbeddingModality.text,
    if (declaredImages) EmbeddingModality.image,
  };

  @override
  PreferredBackend? get activeBackend => PreferredBackend.cpu;

  @override
  bool get isClosed => _closed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async {
    tasks.add(taskType);
    final int scene;
    if (input.text case final text?) {
      scene = _scenes.indexWhere((s) => text.contains(s.split('_').first));
    } else {
      final sent = input.images.single;
      final prepared = _isPrepared(sent);
      final bytes = prepared
          ? Uint8List.sublistView(sent, 0, sent.length - _prepared.length)
          : sent;
      final format = sniffEncodedMediaFormat(bytes);
      const accepted = {'jpeg', 'png', 'gif', 'bmp'};
      if (format == null || !accepted.contains(format.name)) {
        throw EmbeddingFormatNotSupportedException(
          'LiteRT-LM does not decode ${format?.name} images; it accepts JPEG, '
          'PNG, GIF and BMP.',
          modality: EmbeddingModality.image,
          detected: format,
          accepted: const {},
        );
      }
      scene = _byBytes[_key(bytes)] ?? -1;
      if (scene >= 0) {
        _log.add('embed ${prepared ? '' : 'RAW '}${_scenes[scene]}');
      }
    }
    if (scene < 0) throw StateError('the fake knows no vector for $input');
    final vector = List<double>.generate(
      dimension,
      (i) => i == scene ? 1 : 0.1,
    );
    final norm = math.sqrt(vector.fold(0.0, (s, v) => s + v * v));
    return [for (final v in vector) v / norm];
  }

  @override
  void addCloseListener(void Function() listener) {}

  @override
  Future<void> close() async => _closed = true;
}

final class _MemoryPhotos implements PhotoStore {
  _MemoryPhotos(this._log);

  final List<String> _log;
  final kept = <String, Uint8List>{};
  int _n = 0;

  @override
  Future<String> keep(Uint8List bytes, {required String name}) async {
    _log.add('keep $name');
    final reference = '/photos/${_n++}-$name';
    kept[reference] = Uint8List.fromList(bytes);
    return reference;
  }

  @override
  ImageProvider imageFor(String reference) => switch (assetKeyOf(reference)) {
    final key? => MemoryImage(_asset(key)),
    null => MemoryImage(kept[reference]!),
  };

  @override
  Future<Uint8List> read(String reference) async => kept[reference]!;

  @override
  Future<void> forget(String reference) async => kept.remove(reference);

  @override
  Future<void> forgetAll() async => kept.clear();
}

final class _MemoryProvider implements VectorStoreProvider {
  _MemoryProvider(this._store);

  final _MemoryStore _store;

  @override
  String get id => 'memory';

  @override
  String get name => 'memory';

  @override
  int get priority => 0;

  @override
  bool canHandle(VectorStoreSpec spec) => spec.providerId == id;

  @override
  Future<VectorStoreRepository> createStore(VectorStoreSpec spec) async =>
      _store;
}

/// A vector store in memory, ranking by cosine similarity.
final class _MemoryStore extends VectorStoreRepository {
  VectorStoreBinding? binding;

  /// Every addDocument fails, as a full disk would.
  bool failAdds = false;
  final _documents = <String, (String, List<double>)>{};

  Iterable<String> get contents => _documents.values.map((d) => d.$1);

  @override
  bool isInitialized = false;

  @override
  FilterSchema filterSchema = FilterSchema.empty;

  @override
  void configure(FilterSchema schema) => filterSchema = schema;

  @override
  Future<void> initialize(String location) async => isInitialized = true;

  @override
  Future<VectorStoreBinding?> readBinding() async => binding;

  @override
  Future<void> bind(VectorStoreBinding binding) async {
    final existing = this.binding;
    if (existing != null && existing != binding) {
      throw VectorStoreException('already bound to $existing');
    }
    this.binding = binding;
  }

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async {
    if (failAdds) throw const VectorStoreException('disk full');
    _documents[id] = (content, embedding);
  }

  @override
  Future<void> removeDocument({required String id}) async =>
      _documents.remove(id);

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async {
    double dot(List<double> a) => [
      for (var i = 0; i < a.length; i++) a[i] * queryEmbedding[i],
    ].fold(0.0, (s, v) => s + v);
    final hits = [
      for (final MapEntry(key: id, value: (content, vector))
          in _documents.entries)
        RetrievalResult(id: id, content: content, similarity: dot(vector)),
    ]..sort((a, b) => b.similarity.compareTo(a.similarity));
    return hits.take(topK).toList();
  }

  @override
  Future<VectorStoreStats> getStats() async => VectorStoreStats(
    documentCount: _documents.length,
    vectorDimension: binding?.profile.dimension ?? 0,
  );

  @override
  Future<void> clear() async => _documents.clear();

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async => isInitialized = false;
}
