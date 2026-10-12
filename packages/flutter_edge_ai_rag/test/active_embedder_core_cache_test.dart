// FlutterEdgeAiActiveEmbedder against core's REAL embedder cache (R5 §4.6,
// §6.6): the adapters resolve the model per operation through
// FlutterEdgeAi.getActiveEmbedder, so a text index and an image index over one
// installed model share one engine. When the image index asks for images, core
// rebuilds the embedder once with both, closing the text-only one — requests
// queued on it never ran, fail with EmbedderClosedException, and the adapter
// retries them on the replacement. Neither index ever sees that exception.
//
// The embedding pass is a fake (no image engine exists in this train): it
// reports text and image, runs in core's isolate host like a real one, and
// can hold its first request until the test releases it, which is what makes
// "a request queued behind the close" deterministic.
//
// Also: FlutterEdgeAiActiveEmbedder.forActiveModel end to end — ids derived
// from real installs differ per model, and a store bound under one refuses
// the other.
//
// Run: flutter test test/active_embedder_core_cache_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _MultimodalBackend backend;

  // Everything that can fail runs in the test bodies; this only builds a
  // fresh, empty host for each test.
  setUp(() {
    root = Directory.systemTemp.createTempSync('rag_core_cache_');
    PathProviderPlatform.instance = _TempPaths(root.path);
    SharedPreferences.setMockInitialValues({});
    backend = _MultimodalBackend(root.path);
  });

  tearDown(() async {
    await FlutterEdgeAiPlugin.instance.initializedEmbeddingModel?.close();
    await FlutterEdgeAiPlugin.instance.modelManager
        .clearActiveEmbeddingIdentity();
    FlutterEdgeAi.reset();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> initializeAndInstall(String model, {String? tokenizer}) async {
    await FlutterEdgeAi.initialize(embeddingBackends: [backend]);
    var builder = FlutterEdgeAi.installEmbedder().modelFromFile(
      _file(root, model, 1024 * 1024 + 16),
    );
    if (tokenizer != null) {
      builder = builder.tokenizerFromFile(_file(root, tokenizer, 2048));
    }
    await builder.install();
  }

  test('a text index and an image index share one model: one rebuild, and no '
      'EmbedderClosedException ever reaches either', () async {
    await initializeAndInstall('shared.litertlm');
    final rag = FlutterEdgeAiRag(providers: [_MemoryProvider()]);

    var textResolutions = 0;
    final textEmbedder = FlutterEdgeAiActiveEmbedder(
      profileId: 'shared-text-v1',
      modelResolver: () {
        textResolutions++;
        return FlutterEdgeAi.getActiveEmbedder();
      },
    );
    final imageEmbedder = FlutterEdgeAiActiveEmbedder(
      profileId: 'shared-text-v1-vis140',
      supportImage: true,
    );

    final texts = await rag.open(
      spec: VectorStoreSpec(providerId: 'memory', location: 'texts'),
      embedder: textEmbedder,
    );
    expect(backend.describes, [false], reason: 'built once, text only');

    // Hold the text model's first request in the worker so the next two
    // queue behind it, then let the image index widen the embedder.
    final textModel = FlutterEdgeAiPlugin.instance.initializedEmbeddingModel!;
    expect(textResolutions, 1, reason: 'open() resolved the profile once');
    backend.hold();
    final pending = [
      texts.add(id: 't1', document: EmbeddingInput.text('first')),
      texts.add(id: 't2', document: EmbeddingInput.text('second')),
      texts.search(query: EmbeddingInput.text('third')),
    ];
    await backend.firstRequestStarted();
    final openingImages = rag.open(
      spec: VectorStoreSpec(
        providerId: 'memory',
        location: 'photos',
        documents: EmbeddingModality.image,
      ),
      embedder: imageEmbedder,
    );
    // The widening close marks the text model closed and posts the close to
    // its worker in one synchronous step; the worker files it before it takes
    // the next request, so t2 and the search fail as "never ran". Release
    // the held t1 only once that close has begun.
    await _until(() => textModel.isClosed, 'the widening close never began');
    backend.release();

    final images = await openingImages;
    await Future.wait(pending);
    expect(
      textResolutions,
      6,
      reason:
          'open, the three operations, and exactly one retry each for the two '
          'requests the close failed (t1 was in flight and finished)',
    );

    // Alternate: neither index causes another build.
    for (var round = 0; round < 3; round++) {
      await images.add(
        id: 'p$round',
        document: EmbeddingInput.image(_png),
        content: 'content://media/$round',
      );
      await texts.add(id: 'x$round', document: EmbeddingInput.text('x'));
      await images.search(query: EmbeddingInput.text('a photo'));
      await images.search(query: EmbeddingInput.image(_png));
      await texts.search(query: EmbeddingInput.text('x'));
    }

    expect(backend.describes, [
      false,
      true,
    ], reason: 'exactly one rebuild, widened to text + image');
    expect((await texts.stats()).documentCount, 5);
    expect((await images.stats()).documentCount, 3);

    await texts.dispose();
    await images.dispose();
  });

  test('forActiveModel ids follow the installed files', () async {
    await initializeAndInstall('eg-a.tflite', tokenizer: 'eg-a-tokenizer.json');
    final rag = FlutterEdgeAiRag(providers: [_MemoryProvider()]);
    final first = FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'kb');
    final files = [
      for (final file in FlutterEdgeAi.activeEmbedderSpec!.files) file.filename,
    ];
    expect(files, hasLength(2));

    final profile = await first.resolveProfile();
    expect(profile.id, 'kb@${files.join('+')}');
    final index = await rag.open(
      spec: VectorStoreSpec(providerId: 'memory', location: 'kb'),
      embedder: first,
    );
    await index.add(id: 'd', document: EmbeddingInput.text('doc'));
    await index.dispose();

    // A different model under the same namespace gets a different id, and
    // the location bound to the first one refuses it.
    await FlutterEdgeAi.installEmbedder()
        .modelFromFile(_file(root, 'eg-b.litertlm', 1024 * 1024 + 16))
        .install();
    final second = FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'kb');
    expect((await second.resolveProfile()).id, 'kb@eg-b.litertlm');
    await expectLater(
      rag.open(
        spec: VectorStoreSpec(providerId: 'memory', location: 'kb'),
        embedder: second,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('kb@eg-a.tflite'), contains('kb@eg-b.litertlm')),
        ),
      ),
    );

    // And the first adapter, still pinned to the first spec, refuses to run.
    await expectLater(
      first.embedDocument(EmbeddingInput.text('late')),
      throwsStateError,
    );
  });

  test('forActiveModel without an active model is a StateError', () async {
    await FlutterEdgeAi.initialize(embeddingBackends: [backend]);
    expect(
      () => FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: 'kb'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('installEmbedder'),
        ),
      ),
    );
    expect(
      () => FlutterEdgeAiActiveEmbedder.forActiveModel(namespace: ' '),
      throwsArgumentError,
    );
  });
}

Future<void> _until(bool Function() condition, String failure) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(failure);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _file(Directory root, String name, int bytes) {
  final file = File('${root.path}/src/$name')..createSync(recursive: true);
  file.writeAsBytesSync(Uint8List(bytes));
  return file.path;
}

/// A PNG signature: enough for core's format sniffer.
final Uint8List _png = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  0,
  0,
  0,
]);

/// Text and image, 4-dimensional, in core's isolate host. [describes] records
/// `supportImage` per build: one entry per engine core built.
final class _MultimodalBackend extends EmbeddingBackendProvider {
  _MultimodalBackend(this._root);

  final String _root;
  final List<bool> describes = [];

  String get _gate => '$_root/hold.gate';
  String get _started => '$_root/hold.started';

  /// The next request any pass serves blocks until [release].
  void hold() {
    File(_started).deleteIfExists();
    File(_gate).writeAsStringSync('hold');
  }

  void release() => File(_gate).deleteIfExists();

  Future<void> firstRequestStarted() => _until(
    () => File(_started).existsSync(),
    'the held request never started',
  );

  @override
  String get name => 'Fake multimodal';

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    describes.add(config.supportImage);
    return EmbeddingPassDescriptor<_PassConfig>(
      engineTag: 'FakeMultimodal',
      factory: _buildPass,
      config: _PassConfig(gate: _gate, started: _started),
      activeBackend: PreferredBackend.cpu,
    );
  }
}

final class _PassConfig {
  const _PassConfig({required this.gate, required this.started});

  final String gate;
  final String started;
}

EmbeddingPass _buildPass(_PassConfig config) => _FakePass(config);

final class _FakePass extends EmbeddingPass {
  _FakePass(this._config);

  final _PassConfig _config;

  @override
  Future<EmbeddingPassInfo> load() async => EmbeddingPassInfo(
    dimension: 4,
    modalities: const {EmbeddingModality.text, EmbeddingModality.image},
    imageFormats: {EncodedMediaFormat.png},
  );

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    // Blocks the worker the way a native call does, so requests queue.
    if (File(_config.gate).existsSync()) {
      File(_config.started).writeAsStringSync('started');
      while (File(_config.gate).existsSync()) {
        sleep(const Duration(milliseconds: 5));
      }
    }
    return input.images.isNotEmpty ? const [0, 1, 0, 0] : const [1, 0, 0, 0];
  }

  @override
  Future<void> close() async {}
}

extension on File {
  void deleteIfExists() {
    if (existsSync()) deleteSync();
  }
}

/// An in-memory store per location, persistent across opens in one test.
final class _MemoryProvider implements VectorStoreProvider {
  final Map<String, _MemoryStore> _stores = {};

  @override
  String get id => 'memory';

  @override
  String get name => 'Memory';

  @override
  int get priority => 0;

  @override
  bool canHandle(VectorStoreSpec spec) => true;

  @override
  Future<VectorStoreRepository> createStore(VectorStoreSpec spec) async =>
      _stores.putIfAbsent(spec.location, _MemoryStore.new);
}

final class _MemoryStore extends VectorStoreRepository {
  VectorStoreBinding? _binding;
  final Map<String, (String, List<double>)> _documents = {};

  @override
  bool isInitialized = false;

  @override
  FilterSchema filterSchema = FilterSchema.empty;

  @override
  void configure(FilterSchema schema) => filterSchema = schema;

  @override
  Future<void> initialize(String location) async => isInitialized = true;

  @override
  Future<VectorStoreBinding?> readBinding() async => _binding;

  @override
  Future<void> bind(VectorStoreBinding binding) async {
    final existing = _binding;
    if (existing != null && existing != binding) {
      throw VectorStoreException('already bound to $existing');
    }
    _binding = binding;
  }

  @override
  Future<void> addDocument({
    required String id,
    required String content,
    required List<double> embedding,
    String? metadata,
  }) async => _documents[id] = (content, embedding);

  @override
  Future<void> removeDocument({required String id}) async =>
      _documents.remove(id);

  @override
  Future<List<RetrievalResult>> searchSimilar({
    required List<double> queryEmbedding,
    required int topK,
    double threshold = 0.0,
    Filter? filter,
  }) async => [
    for (final MapEntry(key: id, value: (content, _)) in _documents.entries)
      RetrievalResult(id: id, content: content, similarity: 1),
  ].take(topK).toList();

  @override
  Future<VectorStoreStats> getStats() async => VectorStoreStats(
    documentCount: _documents.length,
    vectorDimension: _binding?.profile.dimension ?? 0,
  );

  @override
  Future<void> clear() async => _documents.clear();

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async => isInitialized = false;
}

final class _TempPaths extends PathProviderPlatform {
  _TempPaths(this._root);

  final String _root;

  String _dir(String name) {
    final dir = Directory('$_root/$name')..createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => _dir('documents');

  @override
  Future<String?> getApplicationSupportPath() async => _dir('support');

  @override
  Future<String?> getTemporaryPath() async => _dir('tmp');
}
