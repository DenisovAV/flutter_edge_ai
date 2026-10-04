// Desktop parity for the STT language path (#500).
//
// Why a second file rather than a parameter on the mobile one: `flutter test`
// runs on the VM, and `defaultFlutterEdgeAiInstance()` returns
// `FlutterEdgeAiMobile` there unconditionally — desktop apps get
// `FlutterEdgeAiDesktop` through `dartPluginClass`, which no test ever exercised.
// So the desktop shell had ZERO coverage while being a first-class Whisper
// target: deleting its `RuntimeConfig(language:)` left the whole suite green.
//
// KNOWN GAP, and why the assertions are contract-level rather than
// identity-level: the desktop shell does NOT currently reuse its STT recognizer
// at all. Its guard compares `activeSttModel.name` read NOW against the name
// stored on a previous call, and the two disagree — an install names the spec
// after the basename, the restore-from-preferences path after the full filename
// (`mobile_model_manager.dart:439-440`). So every `getActiveStt()` on desktop
// decides "the model changed", closes the recognizer and rebuilds it. That is a
// PRE-EXISTING defect unrelated to #500; the mobile shell cannot see it because
// it compares two names read at the same moment. Fixing it is a separate change.
//
// These tests therefore assert what the user is PROMISED — the recognizer handed
// back speaks the language that was asked for — which holds whether the shell
// reuses or rebuilds, and keeps holding once the name bug is fixed.
//
// Run: flutter test test/desktop/stt_language_desktop_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/registry/stt_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/stt_registry.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/desktop/flutter_edge_ai_desktop.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

final _fakeBundleBytes = Uint8List(1024 * 1024 + 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp('fg_desktop_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('fg_desktop_supp_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    SttRegistry.instance.reset();
    // The whole point of this file: drive the DESKTOP shell, not the VM default.
    FlutterEdgeAiDesktop.registerWith();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    SttRegistry.instance.reset();
    for (final dir in [fakeDocuments, fakeAppSupport]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  Future<_FakeSttBackend> installWhisper() async {
    await ServiceRegistry.initialize(
      downloadService: _FixtureDownloadService(_fakeBundleBytes),
    );
    final backend = _FakeSttBackend();
    SttRegistry.instance.registerAll([backend]);

    await FlutterEdgeAi.installStt()
        .modelFromNetwork('https://example.com/whisper.tflite')
        .tokenizerFromNetwork('https://example.com/tokenizer.json')
        .ofType(SttModelType.whisper)
        .install();

    return backend;
  }

  test(
    'desktop: the language reaches RuntimeConfig on the first load',
    () async {
      // The original #500 bug, on the shell no test covered: the parameter was
      // accepted and dropped before RuntimeConfig. Deleting `language: language`
      // from the desktop shell's sttConfig fails here.
      final backend = await installWhisper();

      final recognizer = await FlutterEdgeAi.getActiveStt(language: 'de');

      expect(backend.lastConfig?.language, 'de');
      expect(recognizer.language, 'de');

      await recognizer.close();
    },
  );

  test(
    'desktop: a second call in a new language yields that language',
    () async {
      // Contract-level on purpose — see the KNOWN GAP above. Whether the shell
      // retargets the cached recognizer or rebuilds it, the object handed back
      // must speak the requested language.
      await installWhisper();

      final first = await FlutterEdgeAi.getActiveStt(language: 'de');
      expect(first.language, 'de');

      final second = await FlutterEdgeAi.getActiveStt(language: 'fr');
      expect(second.language, 'fr');

      await second.close();
      if (!identical(second, first)) await first.close();
    },
  );
}

class _FakeSttBackend implements SttBackendProvider {
  RuntimeConfig? lastConfig;
  int createModelCallCount = 0;

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
    createModelCallCount++;
    lastConfig = config;
    return _FakeSpeechRecognizer(config.language);
  }
}

class _FakeSpeechRecognizer extends SpeechRecognizer with CloseNotifier {
  _FakeSpeechRecognizer(this.language);

  @override
  String? language;

  @override
  Future<String> transcribe(Uint8List pcm16kMono, {String? language}) async =>
      'ok';

  @override
  Future<void> close() async {
    fireCloseListeners();
  }
}

class _FixedPathProviderPlatform extends PathProviderPlatform {
  final String documentsPath;
  final String appSupportPath;

  _FixedPathProviderPlatform({
    required this.documentsPath,
    required this.appSupportPath,
  });

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => appSupportPath;

  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}

class _FixtureDownloadService implements DownloadService {
  final Uint8List bytes;
  _FixtureDownloadService(this.bytes);

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
