// B89: uninstallEmbedder / uninstallStt / uninstallTts and the model that
// getActiveEmbedder / getActiveStt / getActiveTts built from those files.
//
// Each uninstall closes that model before its files go, as uninstallModel
// closes the inference model (B88): the app's handle stops working, the
// shell forgets it, and a reinstall gets a new one. Before the fix the model
// stayed open and cached, answered from files that were gone, and came back
// from getActive* after a reinstall.
//
// Both shells: the VM default is FlutterEdgeAiMobile; FlutterEdgeAiDesktop is
// what macOS, Linux and Windows apps get, and it caches STT/TTS differently.
//
// Run: flutter test test/core/api/uninstall_loaded_embedder_speech_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/registry/stt_registry.dart';
import 'package:flutter_edge_ai/src/registry/tts_registry.dart';
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

// Clears FileSourceHandler's size floors: 1 MB for model files, 1 KB for
// json and the like.
final _fixtureBytes = Uint8List(1024 * 1024 + 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late Directory appSupport;
  late FlutterEdgeAiPlugin previousPlugin;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('fg_b89_docs_');
    appSupport = await Directory.systemTemp.createTemp('fg_b89_supp_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: documents.path,
      appSupportPath: appSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    previousPlugin = FlutterEdgeAiPlugin.instance;
    _resetRegistries();
    await ServiceRegistry.initialize(
      downloadService: _FixtureDownloadService(_fixtureBytes),
    );
  });

  tearDown(() async {
    FlutterEdgeAiPlugin.instance = previousPlugin;
    _resetRegistries();
    for (final dir in [documents, appSupport]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  for (final shell in _Shell.values) {
    group('${shell.name} shell', () {
      setUp(shell.install);

      test('uninstallEmbedder closes the embedder getActiveEmbedder built '
          'from its files', () async {
        final backend = _FakeEmbeddingBackend();
        EmbeddingRegistry.instance.registerAll([backend]);
        await _installEmbedder();
        final model = await FlutterEdgeAi.getActiveEmbedder();
        expect(
          await model.embed(
            EmbeddingInput.text('a'),
            taskType: TaskType.retrievalQuery,
          ),
          [1.0, 0.0, 0.0],
        );

        await FlutterEdgeAi.uninstallEmbedder();

        expect(model.isClosed, isTrue);
        expect(FlutterEdgeAiPlugin.instance.initializedEmbeddingModel, isNull);
        await expectLater(
          model.embed(
            EmbeddingInput.text('a'),
            taskType: TaskType.retrievalQuery,
          ),
          throwsA(isA<EmbedderClosedException>()),
        );
        await expectLater(
          FlutterEdgeAi.getActiveEmbedder(),
          throwsA(isA<NoActiveModelError>()),
        );

        // Installed again, it is a new embedder.
        await _installEmbedder();
        final again = await FlutterEdgeAi.getActiveEmbedder();
        expect(again, isNot(same(model)));
        expect(backend.describeCalls, 2);
        await again.close();
      });

      test('a decider on the uninstalled embedder fails with '
          'NoActiveModelError, and takes the reinstalled one', () async {
        EmbeddingRegistry.instance.registerAll([_FakeEmbeddingBackend()]);
        await _installEmbedder();
        final model = await FlutterEdgeAi.getActiveEmbedder();
        final decider = await model.createDecider(
          options: [
            DeciderOption('a', examples: [EmbeddingInput.text('a1')]),
            DeciderOption('b', examples: [EmbeddingInput.text('b1')]),
          ],
          calibration: const EmbeddingDeciderCalibration.none(),
        );
        final input = DeciderInput(EmbeddingInput.text('about a'));
        expect((await decider.choose(input)).choice, 'a');

        await FlutterEdgeAi.uninstallEmbedder();

        // The closed embedder's request never ran; core's replacement is
        // the active embedder, and there is none.
        await expectLater(
          decider.choose(input),
          throwsA(isA<NoActiveModelError>()),
        );
        expect(decider.isClosed, isFalse);

        await _installEmbedder();
        expect((await decider.choose(input)).choice, 'a');
        await decider.close();
        await FlutterEdgeAiPlugin.instance.initializedEmbeddingModel?.close();
      });

      test('uninstallStt closes the recognizer getActiveStt built from its '
          'files', () async {
        final backend = _FakeSttBackend();
        SttRegistry.instance.registerAll([backend]);
        await _installStt();
        final recognizer = await FlutterEdgeAi.getActiveStt();
        final first = backend.built.single;

        await FlutterEdgeAi.uninstallStt();

        expect(first.closeCalls, 1, reason: 'closed by the uninstall');
        await expectLater(
          FlutterEdgeAi.getActiveStt(),
          throwsA(isA<StateError>()),
        );

        await _installStt();
        final again = await FlutterEdgeAi.getActiveStt();
        expect(again, isNot(same(recognizer)));
        await again.close();
      });

      test('uninstallTts closes the synthesizer getActiveTts built from its '
          'files', () async {
        final backend = _FakeTtsBackend();
        TtsRegistry.instance.registerAll([backend]);
        await _installTts();
        final synthesizer = await FlutterEdgeAi.getActiveTts();
        final first = backend.built.single;

        await FlutterEdgeAi.uninstallTts();

        expect(first.closeCalls, 1, reason: 'closed by the uninstall');
        await expectLater(
          FlutterEdgeAi.getActiveTts(),
          throwsA(isA<StateError>()),
        );

        // Installed again, it is a new synthesizer, not the cached one.
        await _installTts();
        final again = await FlutterEdgeAi.getActiveTts();
        expect(again, isNot(same(synthesizer)));
        expect(backend.built.length, 2);
        await again.close();
      });
    });
  }
}

enum _Shell {
  mobile,
  desktop;

  void install() => switch (this) {
    _Shell.mobile => FlutterEdgeAiPlugin.instance = FlutterEdgeAiMobile(),
    _Shell.desktop => FlutterEdgeAiDesktop.registerWith(),
  };
}

void _resetRegistries() {
  ServiceRegistry.reset();
  EmbeddingRegistry.instance.reset();
  SttRegistry.instance.reset();
  TtsRegistry.instance.reset();
}

Future<void> _installEmbedder() => FlutterEdgeAi.installEmbedder()
    .modelFromNetwork('https://example.com/b89/embedder.tflite')
    .tokenizerFromNetwork('https://example.com/b89/tokenizer.json')
    .install();

Future<void> _installStt() => FlutterEdgeAi.installStt()
    .modelFromNetwork('https://example.com/b89/stt.tflite')
    .tokenizerFromNetwork('https://example.com/b89/stt_tokenizer.json')
    .ofType(SttModelType.moonshine)
    .install();

Future<void> _installTts() => FlutterEdgeAi.installTts()
    .fromNetwork('https://example.com/b89/matcha/')
    .ofType(TtsModelType.matcha)
    .install();

/// Claims every spec and describes a 3-dimensional fake pass.
final class _FakeEmbeddingBackend extends EmbeddingBackendProvider {
  int describeCalls = 0;

  @override
  String get name => 'FakeEmbedding';

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    describeCalls++;
    return const EmbeddingPassDescriptor<String>(
      engineTag: 'Fake',
      factory: _buildFakePass,
      config: 'fake',
      activeBackend: PreferredBackend.cpu,
    );
  }
}

EmbeddingPass _buildFakePass(String _) => _FakePass();

final class _FakePass extends EmbeddingPass {
  @override
  Future<EmbeddingPassInfo> load() async =>
      const EmbeddingPassInfo(dimension: 3);

  /// a… → x, b… → y, anything else → z: enough for a decider to tell two
  /// options apart.
  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async =>
      switch (input.text?[0]) {
        'a' => const [1.0, 0.0, 0.0],
        'b' => const [0.0, 1.0, 0.0],
        _ => const [0.0, 0.0, 1.0],
      };

  @override
  Future<void> close() async {}
}

class _FakeSttBackend implements SttBackendProvider {
  final built = <_FakeSpeechRecognizer>[];

  @override
  String get name => 'FakeSTT';

  @override
  int get priority => 0;

  @override
  bool canHandle(SttModelSpec spec) => true;

  @override
  Future<SpeechRecognizer> createModel(
    SttModelSpec spec,
    RuntimeConfig config,
  ) async {
    final recognizer = _FakeSpeechRecognizer(config.language);
    built.add(recognizer);
    return recognizer;
  }
}

class _FakeSpeechRecognizer extends SpeechRecognizer with CloseNotifier {
  _FakeSpeechRecognizer(this.language);

  int closeCalls = 0;

  @override
  String? language;

  @override
  Future<String> transcribe(Uint8List pcm16kMono, {String? language}) async =>
      'ok';

  @override
  Future<void> close() async {
    closeCalls++;
    fireCloseListeners();
  }
}

class _FakeTtsBackend implements TtsBackendProvider {
  final built = <_FakeSpeechSynthesizer>[];

  @override
  String get name => 'FakeTTS';

  @override
  int get priority => 0;

  @override
  bool canHandle(TtsModelSpec spec) => true;

  @override
  Future<SpeechSynthesizer> createModel(
    TtsModelSpec spec,
    RuntimeConfig config,
  ) async {
    final synthesizer = _FakeSpeechSynthesizer();
    built.add(synthesizer);
    return synthesizer;
  }
}

class _FakeSpeechSynthesizer extends SpeechSynthesizer with CloseNotifier {
  int closeCalls = 0;

  @override
  int get sampleRate => 22050;

  @override
  Future<Uint8List> synthesize(String text) async => Uint8List(4);

  @override
  Future<void> close() async {
    closeCalls++;
    fireCloseListeners();
  }
}

class _FixedPathProviderPlatform extends PathProviderPlatform {
  _FixedPathProviderPlatform({
    required this.documentsPath,
    required this.appSupportPath,
  });

  final String documentsPath;
  final String appSupportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => appSupportPath;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

/// Writes the fixture wherever a download would land, instead of fetching.
class _FixtureDownloadService implements DownloadService {
  _FixtureDownloadService(this.bytes);

  final Uint8List bytes;

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    await File(targetPath).writeAsBytes(bytes);
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
    await File(targetPath).writeAsBytes(bytes);
    yield 100;
  }
}
