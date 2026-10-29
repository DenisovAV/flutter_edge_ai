// TtsInstallationBuilder.withProgress counts bytes across the bundle: sizes
// read before the first download (HEAD for network files, disk for files
// installed already), each file's own percent weighted by them.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/api/bundle_progress.dart' show sizeOnDisk;
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show TtsModelTypeManifest;
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/src/services/remote_size_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _base = 'https://example.com/matcha/';
final _names = TtsModelType.matcha.manifest;

/// The first file is three times the size of each other one. Each is over
/// the 1 MiB core requires of a `.tflite` model file.
const _unit = 2 * 1024 * 1024;
Map<String, int> _sizes() => {
  for (final (i, name) in _names.indexed) name: i == 0 ? 3 * _unit : _unit,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late Directory support;
  late _Downloads downloads;
  late _Probe probe;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    documents = await Directory.systemTemp.createTemp('tts_progress_docs_');
    support = await Directory.systemTemp.createTemp('tts_progress_support_');
    PathProviderPlatform.instance = _Paths(documents.path, support.path);
    ServiceRegistry.reset();
    downloads = _Downloads(_sizes());
    probe = _Probe(_sizes());
  });

  tearDown(() async {
    ServiceRegistry.reset();
    for (final dir in [documents, support]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  Future<void> initialize({String? huggingFaceToken}) =>
      ServiceRegistry.initialize(
        downloadService: downloads,
        remoteSizeProbe: probe,
        huggingFaceToken: huggingFaceToken,
      );

  TtsInstallationBuilder matcha(List<int> progress, {String base = _base}) =>
      FlutterEdgeAi.installTts()
          .fromNetwork(base)
          .ofType(TtsModelType.matcha)
          .withProgress(progress.add);

  test(
    'weighted by bytes: half of the big first file is 15%, not 6%',
    () async {
      await initialize();
      final progress = <int>[];
      await matcha(progress).install();
      // 3 + 7 x 1 units; half of the first file = 1.5 / 10 units. Counting
      // files would say 50% of 1 of 8 = 6%.
      expect(progress.first, 15);
      expect(probe.asked, hasLength(_names.length));
    },
  );

  test('values only rise and a successful install ends at 100', () async {
    await initialize();
    final progress = <int>[];
    await matcha(progress).install();
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThan(progress[i - 1]), reason: '$progress');
    }
    expect(progress.last, 100);
  });

  test('files installed already count from the start', () async {
    await initialize();
    // A first install stopped after three files leaves them installed.
    final cancel = CancelToken();
    downloads.onDownloaded = () {
      if (downloads.urls.length == 3) cancel.cancel();
    };
    await expectLater(
      FlutterEdgeAi.installTts()
          .fromNetwork(_base)
          .ofType(TtsModelType.matcha)
          .withCancelToken(cancel)
          .install(),
      throwsA(isA<DownloadCancelledException>()),
    );
    downloads.onDownloaded = null;
    probe.asked.clear();

    final progress = <int>[];
    await matcha(progress).install();
    // 3 + 1 + 1 of 10 units are there before any download.
    expect(progress.first, 50);
    expect(progress.last, 100);
    expect(
      probe.asked,
      hasLength(_names.length - 3),
      reason: 'installed files are measured on disk',
    );
  });

  test('a size nobody knows: every file counts the same', () async {
    probe = _Probe({..._sizes()}..remove(_names.last));
    await initialize();
    final progress = <int>[];
    await matcha(progress).install();
    // Equal weights: half of one file of eight is 6%.
    expect(progress.first, 6);
    expect(progress.last, 100);
  });

  test('cancel while the sizes are asked: nothing downloads', () async {
    final gate = Completer<void>();
    probe = _Probe(_sizes(), gate: gate.future);
    await initialize();
    final cancel = CancelToken();
    final install = FlutterEdgeAi.installTts()
        .fromNetwork(_base)
        .ofType(TtsModelType.matcha)
        .withProgress((_) {})
        .withCancelToken(cancel)
        .install();
    for (var i = 0; i < 200 && probe.asked.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(probe.asked, isNotEmpty, reason: 'the HEADs are under way');
    cancel.cancel();
    await expectLater(install, throwsA(isA<DownloadCancelledException>()));
    expect(downloads.urls, isEmpty);
    gate.complete();
  });

  test('a gated repository is asked with the token', () async {
    await initialize(huggingFaceToken: 'hf_registry');
    await FlutterEdgeAi.installTts()
        .fromNetwork(_base, token: 'hf_explicit')
        .ofType(TtsModelType.matcha)
        .withProgress((_) {})
        .install();
    expect(probe.tokens.toSet(), {'hf_explicit'});

    probe.tokens.clear();
    await FlutterEdgeAi.installTts()
        .fromNetwork('https://huggingface.co/org/matcha/resolve/abc/')
        .ofType(TtsModelType.matcha)
        .withProgress((_) {})
        .install();
    expect(probe.tokens.toSet(), {
      'hf_registry',
    }, reason: 'huggingface.co gets the token passed to initialize');
  });

  test('a catalog bundle uses its pinned sizes, with no HEAD', () async {
    await initialize();
    final progress = <int>[];
    await FlutterEdgeAi.installTts()
        .fromCatalog(_MatchaVariant())
        .withProgress(progress.add)
        .install();
    expect(probe.asked, isEmpty);
    expect(progress.first, 15);
  });

  test('100 is said only once the bundle is the active voice', () async {
    await initialize();
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    String? activeAt100;
    await FlutterEdgeAi.installTts()
        .fromNetwork(_base)
        .ofType(TtsModelType.matcha)
        .named('fresh-voice')
        .withProgress((p) {
          if (p == 100) activeAt100 = manager.activeTtsModel?.name;
        })
        .install();
    expect(activeAt100, 'fresh-voice');
  });

  test('a file that is not there has no size, not 0', () async {
    await initialize();
    final fs = ServiceRegistry.instance.fileSystemService;
    expect(await sizeOnDisk(fs, '${documents.path}/none.bin'), isNull);
    final there = File('${documents.path}/there.bin')
      ..writeAsBytesSync(Uint8List(321));
    expect(await sizeOnDisk(fs, there.path), 321);
  });

  test('without withProgress nothing is asked', () async {
    await initialize();
    await FlutterEdgeAi.installTts()
        .fromNetwork(_base)
        .ofType(TtsModelType.matcha)
        .install();
    expect(probe.asked, isEmpty);
  });
}

/// Answers each URL's size by its file name; records what it was asked.
final class _Probe implements RemoteSizeProbe {
  _Probe(this._sizes, {this.gate});

  final Map<String, int> _sizes;
  final Future<void>? gate;
  final asked = <String>[];
  final tokens = <String?>[];

  @override
  Future<int?> sizeOf(
    String url, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    asked.add(url);
    tokens.add(token);
    if (gate case final gate?) await gate;
    return _sizes[Uri.parse(url).pathSegments.last];
  }
}

/// Writes each file at its size, reporting 50 and then 100.
final class _Downloads implements DownloadService {
  _Downloads(this._sizes);

  final Map<String, int> _sizes;
  final urls = <String>[];
  void Function()? onDownloaded;

  Uint8List _bytesFor(String url) =>
      Uint8List(_sizes[Uri.parse(url).pathSegments.last] ?? 16);

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    urls.add(url);
    await File(targetPath).writeAsBytes(_bytesFor(url));
    onDownloaded?.call();
  }

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) async* {
    urls.add(url);
    yield 50;
    await File(targetPath).writeAsBytes(_bytesFor(url));
    onDownloaded?.call();
    yield 100;
  }
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.documents, this.support);

  final String documents;
  final String support;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

/// The Matcha bundle as a catalog lists it, with [_sizes].
final class _MatchaVariant extends TtsVariant {
  @override
  List<ModelArtifact> get files => [
    for (final MapEntry(key: name, value: size) in _sizes().entries)
      ModelArtifact(
        repo: 'org/matcha',
        revision: '0123456789abcdef0123456789abcdef01234567',
        path: name,
        sha256: 'aa',
        sizeBytes: size,
        installFilename: name,
      ),
  ];

  @override
  TtsModelType get type => TtsModelType.matcha;

  @override
  String get baseUrl => _base;

  @override
  String get id => 'matcha/bundle';

  @override
  String get modelId => 'matcha';

  @override
  String get catalogName => 'test_catalog';

  @override
  Set<PreferredBackend> get backendsHere => const {PreferredBackend.cpu};
}
