// #500: `getActiveStt(language:)` must take effect on EVERY call, not just the
// first one in a process.
//
// The STT singleton cache (FlutterEdgeAiMobile.createSttModel) keys its "reuse
// the existing recognizer" branch on the active model's name. The first fix for
// #500 added a `language` parameter and stopped there, so the second
// `getActiveStt(language: 'de')` for the same active model returned the
// recognizer built for the FIRST language and transcribed into it — no error,
// no log in release, and a fluent English translation of German audio, which is
// indistinguishable from success.
//
// That is the same shape the TTS path already had and already fixed; see
// tts_language_singleton_test.dart, whose fixtures this file mirrors. TTS chose
// to fail loud (throw, close first). STT does not have to: Whisper's decoder
// prompt is rebuilt per transcription, so the language is a settable property
// on the recognizer and retargeting costs nothing. This test pins THAT — the
// recognizer is reused, not rebuilt, and its language follows the request.
//
// A real end-to-end test against the ACTUAL FlutterEdgeAiMobile/FlutterEdgeAi
// facade, not a simulation of the completer logic — the bug lived in the shell,
// so a test that reimplements the shell would have passed while shipping it.
//
// Run: flutter test test/mobile/stt_language_singleton_test.dart

import 'dart:async';
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
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

// FileSourceHandler enforces a per-extension minimum size; this clears both the
// 1KB (json) and 1MB (tflite) floors with one fixture.
final _fakeBundleBytes = Uint8List(1024 * 1024 + 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_docs_',
    );
    fakeAppSupport = await Directory.systemTemp.createTemp(
      'flutter_edge_ai_appsupport_',
    );
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    SttRegistry.instance.reset();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    SttRegistry.instance.reset();
    for (final dir in [fakeDocuments, fakeAppSupport]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  Future<_FakeSttBackend> installWhisper({
    Duration? loadDelay,
    bool rejectLanguage = false,
  }) async {
    await ServiceRegistry.initialize(
      downloadService: _FixtureDownloadService(_fakeBundleBytes),
    );
    final backend = _FakeSttBackend(
      loadDelay: loadDelay,
      rejectLanguage: rejectLanguage,
    );
    SttRegistry.instance.registerAll([backend]);

    await FlutterEdgeAi.installStt()
        .modelFromNetwork('https://example.com/whisper.tflite')
        .tokenizerFromNetwork('https://example.com/tokenizer.json')
        .ofType(SttModelType.whisper)
        .install();

    return backend;
  }

  test('language reaches RuntimeConfig on the first call', () async {
    // The ORIGINAL #500 bug: the parameter existed on four signatures and was
    // dropped before RuntimeConfig, so it compiled, ran, and did nothing. Any
    // shell that stops forwarding it fails here.
    final backend = await installWhisper();

    final recognizer = await FlutterEdgeAi.getActiveStt(language: 'de');
    addTearDown(recognizer.close);

    expect(backend.lastConfig?.language, 'de');
    expect(backend.createModelCallCount, 1);
    expect(recognizer.language, 'de');
  });

  test('a second call with a DIFFERENT language retargets the same '
      'recognizer instead of silently reusing the first language', () async {
    final backend = await installWhisper();

    final first = await FlutterEdgeAi.getActiveStt(language: 'en');
    addTearDown(first.close);
    expect(first.language, 'en');
    expect(backend.createModelCallCount, 1);

    final second = await FlutterEdgeAi.getActiveStt(language: 'de');

    // The singleton is REUSED — no reload, no isolate respawn, and the caller's
    // existing handle is not closed underneath them.
    expect(identical(second, first), isTrue);
    expect(backend.createModelCallCount, 1);

    // …and it now speaks German. This is the assertion the shipped code failed:
    // before the fix `second.language` was still 'en'.
    expect(second.language, 'de');
    expect(first.language, 'de', reason: 'same object, so it must agree');
  });

  test('a later call with no language clears the override back to the '
      "model's own default", () async {
    // `null` must mean "the model's default", not "keep whatever was last set".
    // A guard written as `if (language != null) cached.language = language`
    // would strand a caller who explicitly asked to go back to the default.
    final backend = await installWhisper();

    final recognizer = await FlutterEdgeAi.getActiveStt(language: 'de');
    addTearDown(recognizer.close);
    expect(recognizer.language, 'de');

    final again = await FlutterEdgeAi.getActiveStt();

    expect(identical(again, recognizer), isTrue);
    expect(again.language, isNull);
    expect(backend.createModelCallCount, 1);
  });

  test(
    'the per-call override on transcribe does not disturb the default',
    () async {
      final backend = await installWhisper();

      final recognizer = await FlutterEdgeAi.getActiveStt(language: 'de');
      addTearDown(recognizer.close);
      await recognizer.transcribe(Uint8List(16), language: 'fr');

      expect(backend.recognizer.lastTranscribeLanguage, 'fr');
      // A per-call value that leaked into the default would make the NEXT call
      // French too — the same stale-state class of bug, one layer down.
      expect(recognizer.language, 'de');

      await recognizer.transcribe(Uint8List(16));
      expect(backend.recognizer.lastTranscribeLanguage, 'de');
    },
  );
  test(
    'a caller arriving DURING the first load still gets its language',
    () async {
      // The in-flight-completer branch. The first fix patched only the
      // already-built branch, so a language picked while the model was still
      // loading was dropped with no error — the #500 failure, narrowed to a
      // window wide enough to hold an isolate spawn and a tokenizer parse.
      final backend = await installWhisper(
        loadDelay: const Duration(milliseconds: 500),
      );

      final first = FlutterEdgeAi.getActiveStt(); // deliberately not awaited
      // Wait for the first load to actually START. Without this the test relied
      // on the first call finishing its file-path preamble before the second
      // one did; on a loaded machine the I/O finished in the other order, the
      // 'de' call built the model and the null call retargeted it back, so it
      // was green alone and red in tool/test_all.sh.
      await backend.loadStarted.future;
      final second = await FlutterEdgeAi.getActiveStt(language: 'de');
      addTearDown(second.close);
      final firstResolved = await first;

      expect(backend.createModelCallCount, 1, reason: 'must not build twice');
      expect(identical(second, firstResolved), isTrue);
      expect(second.language, 'de');
    },
  );

  test('the explicit-paths API retargets too', () async {
    // `createSttModel`'s dartdoc promises it retargets an existing recognizer.
    // On the legacy arm it returned the first call's recognizer unchanged.
    final backend = await installWhisper();

    final first = await FlutterEdgeAiPlugin.instance.createSttModel(
      modelPath: '/tmp/whisper.tflite',
      tokenizerPath: '/tmp/tokenizer.json',
      language: 'de',
    );
    addTearDown(first.close);
    expect(first.language, 'de');

    final second = await FlutterEdgeAiPlugin.instance.createSttModel(
      modelPath: '/tmp/whisper.tflite',
      tokenizerPath: '/tmp/tokenizer.json',
      language: 'fr',
    );

    expect(identical(second, first), isTrue);
    expect(second.language, 'fr');
    expect(backend.createModelCallCount, 1);
  });

  test(
    'a rejected language propagates instead of poisoning the recognizer',
    () async {
      // The real recognizer's setter throws for a language its model cannot use
      // (moonshine has no language token). Before validation moved into the
      // setter, the retarget branch assigned it anyway and returned normally —
      // and then EVERY later transcribe(), including ones passing no language,
      // failed. A call documented to throw instead broke the recognizer.
      final backend = await installWhisper(rejectLanguage: true);

      final recognizer = await FlutterEdgeAi.getActiveStt();
      addTearDown(recognizer.close);
      expect(recognizer.language, isNull);

      await expectLater(
        FlutterEdgeAi.getActiveStt(language: 'de'),
        throwsArgumentError,
      );

      // …and the rejected value must not have been stored.
      expect(recognizer.language, isNull);
      expect(backend.createModelCallCount, 1);
    },
  );
}

class _FakeSttBackend implements SttBackendProvider {
  _FakeSttBackend({this.loadDelay, this.rejectLanguage = false});

  /// Holds `createModel` open so a second caller lands on the in-flight
  /// completer branch instead of the already-built one.
  final Duration? loadDelay;

  /// Makes the recognizer's `language` setter throw, the way
  /// `LiteRtSpeechRecognizer` does for a language its model cannot use. The
  /// shells must let that propagate rather than swallow it.
  final bool rejectLanguage;

  RuntimeConfig? lastConfig;
  int createModelCallCount = 0;

  /// Completes when the first `createModel` starts, i.e. once the shell has
  /// installed its in-flight completer, so a caller that waits for it is
  /// guaranteed to land on the in-flight branch.
  final loadStarted = Completer<void>();
  late _FakeSpeechRecognizer recognizer;

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
    if (!loadStarted.isCompleted) loadStarted.complete();
    if (loadDelay != null) await Future<void>.delayed(loadDelay!);
    return recognizer = _FakeSpeechRecognizer(
      config.language,
      rejectLanguage: rejectLanguage,
    );
  }
}

/// Stands in for `LiteRtSpeechRecognizer`, reproducing the one behaviour under
/// test: `language` is mutable state consulted per `transcribe`, with the
/// per-call argument winning.
class _FakeSpeechRecognizer extends SpeechRecognizer with CloseNotifier {
  _FakeSpeechRecognizer(String? language, {this.rejectLanguage = false})
    : _language = language;

  final bool rejectLanguage;
  String? _language;

  @override
  String? get language => _language;

  @override
  set language(String? value) {
    if (value != null && rejectLanguage) {
      throw ArgumentError.value(value, 'language', 'model has no language');
    }
    _language = value;
  }

  String? lastTranscribeLanguage;

  @override
  Future<String> transcribe(Uint8List pcm16kMono, {String? language}) async {
    lastTranscribeLanguage = language ?? this.language;
    return 'ok';
  }

  @override
  Future<void> close() async {
    fireCloseListeners();
  }
}

/// PathProviderPlatform stub returning fixed, distinct paths (mirrors
/// tts_language_singleton_test.dart).
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

/// Writes [bytes] to whatever targetPath it is asked for, instead of making a
/// real HTTP request.
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
