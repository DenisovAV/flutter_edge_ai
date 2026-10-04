// Two getActiveModel calls that RACE must not silently share one model.
//
// The reuse check in the shells compares the requested params against the
// cached model — but only when a cached model exists. In the window where a
// build is still in flight there is no cached model, and the code below it
// simply returned the pending completer's future to whoever arrived second.
// So a caller asking for GPU while a CPU build was in flight received the CPU
// model, with no error and nothing in the log: the same defect as the
// name-only reuse check, in the one window that check cannot see.
//
// End-to-end against the real FlutterEdgeAi facade (not a re-implementation of
// the completer logic), using the fixture pattern from
// tts_language_singleton_test.dart — the engine is faked, everything above it
// is the shipping code.
//
// Run: flutter test test/mobile/concurrent_get_active_model_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/inference_engine_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

final _fakeBundleBytes = Uint8List(1024 * 1024 + 16);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocuments;
  late Directory fakeAppSupport;

  setUp(() async {
    fakeDocuments = await Directory.systemTemp.createTemp('fg_race_docs_');
    fakeAppSupport = await Directory.systemTemp.createTemp('fg_race_support_');
    PathProviderPlatform.instance = _FixedPathProviderPlatform(
      documentsPath: fakeDocuments.path,
      appSupportPath: fakeAppSupport.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    EngineRegistry.instance.reset();
  });

  tearDown(() async {
    // FlutterEdgeAiMobile is a singleton: its _initCompleter / _initializedModel
    // / _inFlightRequest outlive a test, and FlutterEdgeAi.reset() deliberately
    // does NOT touch them (it resets the DI registry, and documents that the
    // active inference model survives). Closing the cached model is what fires
    // the close listener that clears them. Without this, the first test's
    // leftover in-flight build reappeared inside the second one, which then
    // reported a config difference no test in it had asked for.
    await FlutterEdgeAiPlugin.instance.initializedModel?.close();
    ServiceRegistry.reset();
    EngineRegistry.instance.reset();
    for (final dir in [fakeDocuments, fakeAppSupport]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  Future<_GatedEngine> installWithGatedEngine() async {
    await ServiceRegistry.initialize(
      downloadService: _FixtureDownloadService(_fakeBundleBytes),
    );
    final engine = _GatedEngine();
    EngineRegistry.instance.registerAll([engine]);
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
    ).fromNetwork('https://example.com/model.bin').install();
    return engine;
  }

  test('loraRanks reaches the comparison, not just the comparator', () async {
    // Found by review. ActiveModelParams gained loraRanks as its tenth knob
    // and runtime_config_test proves the COMPARATOR handles it — but both
    // shells built requestedParams with nine fields and stopped, so the value
    // was always null on both sides and always compared equal. The knob was
    // uncompared again: moved out of the comparator and into the call site,
    // where the unit test cannot see it because it never goes through a shell.
    //
    // Driven through FlutterEdgeAiPlugin.instance.createModel rather than
    // FlutterEdgeAi.getActiveModel: loraRanks is a createModel knob, and the
    // facade does not expose it. That is also why the earlier count assertion
    // in runtime_config_test read "nine" and looked right.
    final engine = await installWithGatedEngine();
    engine.release();

    final plugin = FlutterEdgeAiPlugin.instance;
    final a = await plugin.createModel(
      modelType: ModelType.gemmaIt,
      maxTokens: 1024,
      loraRanks: const [4],
    );
    expect(engine.createModelCallCount, 1);

    final b = await plugin.createModel(
      modelType: ModelType.gemmaIt,
      maxTokens: 1024,
      loraRanks: const [16],
    );
    expect(
      engine.createModelCallCount,
      2,
      reason: 'a different LoRA rank is a different model',
    );
    expect(identical(a, b), isFalse);
    // And the value actually REACHED the engine. Counting rebuilds alone would
    // stay green for a shell that compares loraRanks and then drops it before
    // building — which is exactly what desktop did. A knob that forces a
    // multi-gigabyte reload and then is not sent is worse than one that is
    // ignored outright.
    expect(engine.configs.last.loraRanks, [16]);
    expect(engine.configs.first.loraRanks, [4]);

    // An identical rank still reuses — the guard must not be so strict that
    // every call rebuilds.
    final c = await plugin.createModel(
      modelType: ModelType.gemmaIt,
      maxTokens: 1024,
      loraRanks: const [16],
    );
    expect(engine.createModelCallCount, 2);
    expect(identical(c, b), isTrue);

    await b.close();
  });

  test(
    'activationDataType reaches the engine, and a change rebuilds',
    () async {
      // The fix for GPUs that write wrong digits is this one value. Dropped
      // anywhere between the facade and the engine, the model still loads —
      // at the precision that corrupts the figures — so nothing else would
      // notice.
      final engine = await installWithGatedEngine();
      engine.release();

      final f32 = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        activationDataType: ActivationDataType.float32,
      );
      expect(
        engine.configs.last.activationDataType,
        ActivationDataType.float32,
      );

      final same = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        activationDataType: ActivationDataType.float32,
      );
      expect(engine.createModelCallCount, 1);
      expect(identical(same, f32), isTrue);

      // Null is not "float32 by default": it hands the choice back to the model
      // file, which is a different engine.
      final unset = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      expect(engine.createModelCallCount, 2);
      expect(engine.configs.last.activationDataType, isNull);
      expect(identical(unset, f32), isFalse);

      await unset.close();
    },
  );

  test('a caller arriving mid-close is not handed the closing model', () async {
    // Scope, stated because the first version of this test implied more than it
    // checks: the guarantee is that C is not handed the model that was ALREADY
    // closing. It is not that C's model survives.
    //
    // Only one model is cached, so when two callers want different params one
    // of them loses — that is the singleton contract, and a race just decides
    // who. Concretely, B can resume after C has built, re-enter, find params it
    // does not want, and close C's model. A caller must therefore not hold a
    // model across another getActiveModel with different params; the assertion
    // at the end of this test pins that behaviour rather than hiding it.
    // The reuse check reads five fields, and the rebuild branch used to clear
    // them AFTER awaiting close(). During that await every field was still
    // populated, so a caller whose params matched the OLD model passed the
    // reuse check and received a model that was already closing.
    //
    // Needs a fake whose listeners fire after an asynchronous gap — see
    // _FakeInferenceModel.close(). With synchronous firing this window does
    // not exist and the test cannot fail.
    final engine = await installWithGatedEngine();
    engine.release();

    final first = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.cpu,
    );
    expect(engine.createModelCallCount, 1);

    // B forces a rebuild and suspends inside close().
    final b = FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.gpu,
    );
    // C asks for the OLD config while that close is in flight.
    final c = FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.cpu,
    );

    final modelB = await b;
    final modelC = await c;

    // Neither may be the closed model.
    expect(identical(modelB, first), isFalse);
    expect(
      identical(modelC, first),
      isFalse,
      reason: 'C was handed the model that was closing',
    );
    expect((first as dynamic).isClosed, isTrue);

    // The known consequence, asserted so it cannot change silently: the loser
    // of the race holds a model the winner closed. Documented above.
    final bWonLast = !identical(modelB, modelC);
    if (bWonLast) {
      expect(
        (modelC as dynamic).isClosed || (modelB as dynamic).isClosed,
        isTrue,
        reason: 'one of the two racing models must have been torn down',
      );
    }

    await modelB.close();
    if (!identical(modelC, modelB)) await modelC.close();
  });

  test('a failed build does not trap every later request', () async {
    // Found by review, and it is the reason the re-entry above needed a guard
    // of its own. The three pre-build checks (model not installed, no file
    // paths, file missing) completed the completer with an error and returned
    // WITHOUT clearing _initCompleter — the defect FIX #170 removed from the
    // catch block, in the paths it did not cover.
    //
    // Alone that meant every later caller was handed the same dead completer
    // and the same stale error. Combined with the in-flight re-entry, it
    // became unbounded: a DIFFERENT request awaited that completer, caught the
    // error, re-entered, found the very same completer still installed, and
    // looped without end.
    //
    // Both calls carry a deadline, so a regression fails in seconds rather
    // than hanging the suite.
    final engine = await installWithGatedEngine();
    engine.release(); // never reaches the engine; nothing to gate

    // Delete the installed file out from under the plugin.
    final installed = fakeAppSupport
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.bin'))
        .toList();
    expect(installed, isNotEmpty, reason: 'fixture should have written a file');
    for (final f in installed) {
      f.deleteSync();
    }

    await expectLater(
      FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
      ).timeout(const Duration(seconds: 5)),
      throwsA(isA<Exception>()),
    );

    // A DIFFERENT request must also fail — promptly, and on its own merits.
    await expectLater(
      FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
      ).timeout(const Duration(seconds: 5)),
      throwsA(isA<Exception>()),
    );

    // And it must not have been served the first call's dead completer: the
    // engine was never reached either time.
    expect(engine.createModelCallCount, 0);

    // The sharpest check, and the one that pins the state RESET rather than
    // the outcome. Put the file back and repeat the request whose params match
    // the last attempt — 2048, not 1024. That matters: an identical request
    // takes the `return completer.future` path, which the loop guard never
    // runs on, so a trapped completer replays the stale error and never
    // reaches the engine. Asking with 1024 here would instead take the
    // differing-params path, where the guard rescues it and the assertion
    // passes whether or not the early exits reset — which is exactly what the
    // first version of this check did, and why it caught nothing.
    for (final f in installed) {
      f.writeAsBytesSync(_fakeBundleBytes);
    }
    final recovered = await FlutterEdgeAi.getActiveModel(
      maxTokens: 2048,
    ).timeout(const Duration(seconds: 5));
    expect(engine.createModelCallCount, 1, reason: 'must build, not replay');
    await recovered.close();
  });

  test('a second caller with DIFFERENT params does not get the in-flight '
      'model built for the first', () async {
    final engine = await installWithGatedEngine();

    // A starts and blocks inside the engine.
    final a = FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.cpu,
    );
    await engine.started.first;
    expect(engine.createModelCallCount, 1);

    // B arrives mid-build asking for a DIFFERENT backend.
    final b = FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.gpu,
    );
    // Let B reach the in-flight branch before A is released, so this really
    // exercises the race and not a sequential pair of calls.
    await pumpEventQueue();

    engine.release();
    final modelA = await a;
    final modelB = await b;

    // The regression: ONE build, and both callers holding it.
    expect(
      engine.createModelCallCount,
      2,
      reason: 'B must get its own build, not A\'s',
    );
    expect(identical(modelA, modelB), isFalse);
    expect(engine.configs.first.preferredBackend, PreferredBackend.cpu);
    expect(engine.configs.last.preferredBackend, PreferredBackend.gpu);

    await modelB.close();
  });

  test(
    'a second caller with the SAME params shares the in-flight build',
    () async {
      // The guard must not be so strict that it rebuilds for an identical
      // request — sharing one build is the whole point of the completer.
      final engine = await installWithGatedEngine();

      final a = FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.cpu,
      );
      await engine.started.first;
      final b = FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.cpu,
      );
      await pumpEventQueue();

      engine.release();
      final modelA = await a;
      final modelB = await b;

      expect(engine.createModelCallCount, 1);
      expect(identical(modelA, modelB), isTrue);

      await modelA.close();
    },
  );

  test(
    'params the engines normalise away do not split an in-flight build',
    () async {
      // maxNumImages is dropped entirely when vision is off, so these two
      // requests build a bit-identical engine and must share it.
      final engine = await installWithGatedEngine();

      final a = FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      await engine.started.first;
      final b = FlutterEdgeAi.getActiveModel(maxTokens: 1024, maxNumImages: 4);
      await pumpEventQueue();

      engine.release();
      final modelA = await a;
      final modelB = await b;

      expect(engine.createModelCallCount, 1);
      expect(identical(modelA, modelB), isTrue);

      await modelA.close();
    },
  );

  test(
    'getActiveModel(defaults:) threads the merged runtime into RuntimeConfig',
    () async {
      // Guards the actual wiring, not just the pure mergeRuntimeDefault helper:
      // a refactor that computes eff* and then passes the raw params to
      // createModel would keep the unit test green but be caught here.
      final engine = await installWithGatedEngine();
      engine.release();

      // Manifest defaults with no explicit args → merged values reach the engine.
      final m1 = await FlutterEdgeAi.getActiveModel(
        defaults: const ModelRuntimeDefaults(
          maxTokens: 2048,
          supportImage: true,
          preferredBackend: PreferredBackend.gpu,
        ),
      );
      expect(engine.configs.last.maxTokens, 2048);
      expect(engine.configs.last.supportImage, isTrue);
      expect(engine.configs.last.preferredBackend, PreferredBackend.gpu);

      // Explicit argument wins over the manifest default (and rebuilds).
      final m2 = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        defaults: const ModelRuntimeDefaults(maxTokens: 2048),
      );
      expect(engine.configs.last.maxTokens, 512);
      expect(identical(m1, m2), isFalse);

      await FlutterEdgeAiPlugin.instance.initializedModel?.close();
    },
  );
}

/// An engine whose createModel blocks until [release] is called, so a test can
/// hold a build "in flight" deterministically instead of racing a timer.
class _GatedEngine implements InferenceEngineProvider {
  final configs = <RuntimeConfig>[];
  int createModelCallCount = 0;

  final _startedController = StreamController<void>.broadcast();
  Stream<void> get started => _startedController.stream;

  // Once opened, STAYS open. The first cut released only the gate that
  // happened to be pending, so the rebuild this fix triggers created a second
  // gate that nothing ever released and every test hung — including the two
  // that then inherited the leaked in-flight state from the first.
  bool _open = false;
  Completer<void>? _gate;
  void release() {
    _open = true;
    _gate?.complete();
    _gate = null;
  }

  @override
  String get name => 'Gated';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) => true;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    createModelCallCount++;
    configs.add(config);
    if (!_open) {
      final gate = _gate = Completer<void>();
      // Announce AFTER the counter/gate are set, so a test awaiting `started`
      // knows release() has something to release.
      scheduleMicrotask(() => _startedController.add(null));
      await gate.future;
    }
    return _FakeInferenceModel(config);
  }
}

class _FakeInferenceModel with CloseNotifier implements InferenceModel {
  _FakeInferenceModel(this.config);
  final RuntimeConfig config;

  /// Set the moment close() is entered, before the asynchronous gap — so a
  /// test can tell "this model is on its way out" from "this model is gone".
  bool isClosed = false;

  /// Fires the close listeners only AFTER an asynchronous gap, which is what
  /// every real model does — MobileInferenceModel awaits `_session.close()`
  /// (a platform-channel round trip) and FfiInferenceModel awaits
  /// `ffiClient.shutdown()` before firing.
  ///
  /// The first version of this fake fired them synchronously. That collapsed
  /// the whole close window, so no test here could reach the state a caller
  /// arriving mid-close observes — which is exactly where two of the bugs in
  /// this file lived.
  @override
  Future<void> close() async {
    isClosed = true;
    await Future<void>.delayed(Duration.zero);
    fireCloseListeners();
  }

  // The shell only calls close() and addCloseListener() on the model it
  // caches. Anything else reaching this fake is a change in what the shell
  // does with a cached model, and should fail loudly rather than return null.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
