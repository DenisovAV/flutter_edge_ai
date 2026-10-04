import 'dart:async';
// Pins the WIRING of noticeEmbedderBackendIgnored, which the unit tests for the
// notice itself cannot see.
//
// Why each shell is driven DIRECTLY instead of through `FlutterEdgeAi
// .getActiveEmbedder`: on a desktop test host `FlutterEdgeAiPlugin.instance`
// resolves to the desktop shell, and desktop was the one shell that already
// called the notice on its create path. A test that went through the facade
// would have been green while mobile and web stayed silent on the first — and
// usually only — call an app makes.
//
// Each case asks for an embedder with no active identity, so the call throws.
// That is deliberate: the notice must fire BEFORE anything else in
// createEmbeddingModel, so the throw proves nothing about the notice and the
// captured output proves everything.
//
// Run: flutter test test/core/embedding/embedder_notice_wiring_test.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/core/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_edge_ai/desktop/flutter_edge_ai_desktop.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> printed;
  late DebugPrintCallback original;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetEmbedderBackendNotice();
    printed = <String>[];
    original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };
  });

  tearDown(() => debugPrint = original);

  Iterable<String> notices() =>
      printed.where((l) => l.contains('preferredBackend'));

  /// One call, no prior embedder — the shape an app actually uses.
  Future<void> firstCall(FlutterEdgeAiPlugin plugin) async {
    await expectLater(
      plugin.createEmbeddingModel(preferredBackend: PreferredBackend.gpu),
      throwsStateError,
    );
  }

  group('the notice reaches the first call, not only a reuse', () {
    test('mobile', () async {
      await firstCall(FlutterEdgeAiMobile());
      expect(
        notices(),
        hasLength(1),
        reason:
            'a single getActiveEmbedder(preferredBackend:) is the ordinary '
            'shape; if it only speaks on the second call it never speaks',
      );
    });

    test('desktop', () async {
      await firstCall(FlutterEdgeAiDesktop.instance);
      expect(notices(), hasLength(1));
    });
  });

  group('explicit paths go through the same comparison', () {
    late _CountingBackend backend;

    setUp(() {
      EmbeddingRegistry.instance.reset();
      backend = _CountingBackend();
      EmbeddingRegistry.instance.registerAll([backend]);
    });

    tearDown(() => EmbeddingRegistry.instance.reset());

    test(
      'a different model file rebuilds instead of serving the cache',
      () async {
        final plugin = FlutterEdgeAiMobile();

        final first = await plugin.createEmbeddingModel(
          modelPath: '/a.tflite',
          tokenizerPath: '/a.json',
        );
        expect(backend.seenModelPaths, ['/a.tflite']);

        // Same file again: reuse, and the SAME instance.
        final again = await plugin.createEmbeddingModel(
          modelPath: '/a.tflite',
          tokenizerPath: '/a.json',
        );
        expect(backend.seenModelPaths, ['/a.tflite']);
        expect(identical(first, again), isTrue);

        // Different file: must rebuild. Returning the cache here is how a caller
        // asking for another model silently got the previous model's vectors.
        final second = await plugin.createEmbeddingModel(
          modelPath: '/b.tflite',
          tokenizerPath: '/b.json',
        );
        expect(backend.seenModelPaths, ['/a.tflite', '/b.tflite']);
        expect(identical(first, second), isFalse);
      },
    );

    test('two concurrent first calls build ONE embedder, not two', () async {
      // The cached model is only recorded after the build returns, so a guard
      // that waited for it let the second caller start its own build: two
      // worker isolates, two compiles, and the loser orphaned with nobody to
      // close it.
      final plugin = FlutterEdgeAiMobile();
      backend.gate = Completer<void>();

      final a = plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/a.json',
      );
      // Let the first call reach the backend before the second arrives.
      await Future<void>.delayed(Duration.zero);
      final b = plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/a.json',
      );

      backend.gate!.complete();
      final models = await Future.wait([a, b]);

      expect(backend.seenModelPaths, ['/a.tflite']);
      expect(identical(models[0], models[1]), isTrue);
    });

    // Driven against BOTH native shells, because the rule lives in one shared
    // cache but each shell has to wrap its own entry point in
    // EmbedderCache.serialize. A shell that forgets the wrapper passes every
    // unit test the cache has and still races.
    for (final shell in _shells) {
      test('${shell.name}: a concurrent DIFFERENT request is served its own '
          'model, not the one already building', () async {
        final plugin = shell.create();
        addTearDown(() => plugin.initializedEmbeddingModel?.close());
        backend.gate = Completer<void>();

        final a = plugin.createEmbeddingModel(
          modelPath: '/a.tflite',
          tokenizerPath: '/a.json',
        );
        await Future<void>.delayed(Duration.zero);
        // Arrives while /a is still compiling and asks for something else.
        // Joining the build in flight here is how a caller got another model's
        // vectors with no error and no log.
        final b = plugin.createEmbeddingModel(
          modelPath: '/b.tflite',
          tokenizerPath: '/b.json',
        );

        backend.gate!.complete();
        final models = await Future.wait([a, b]);

        expect(backend.seenModelPaths, ['/a.tflite', '/b.tflite']);
        expect(identical(models[0], models[1]), isFalse);
        // The discriminating part. Two callers that merely raced would each
        // record their own model, the last writer would win the cache and the
        // loser would leak unclosed. Serialised, /b's request SEES /a in the
        // cache and closes it — which is the only reason the counts above are
        // not also reachable by racing.
        expect(
          (models[0] as _InertEmbeddingModel).closed,
          isTrue,
          reason: '/a was superseded, so the rebuild must have closed it',
        );
        expect(plugin.initializedEmbeddingModel, same(models[1]));
      });

      test(
        '${shell.name}: three concurrent callers leave one live embedder',
        () async {
          final plugin = shell.create();
          addTearDown(() => plugin.initializedEmbeddingModel?.close());
          backend.gate = Completer<void>();

          final calls = [
            plugin.createEmbeddingModel(
              modelPath: '/a.tflite',
              tokenizerPath: '/a.json',
            ),
            plugin.createEmbeddingModel(
              modelPath: '/b.tflite',
              tokenizerPath: '/b.json',
            ),
            plugin.createEmbeddingModel(
              modelPath: '/b.tflite',
              tokenizerPath: '/b.json',
            ),
          ];
          backend.gate!.complete();
          final models = await Future.wait(calls);

          expect(backend.seenModelPaths, [
            '/a.tflite',
            '/b.tflite',
          ], reason: 'the third caller matches the second and reuses it');
          expect(identical(models[1], models[2]), isTrue);
          expect(
            plugin.initializedEmbeddingModel,
            same(models[2]),
            reason: 'the survivor is what the last request asked for',
          );
        },
      );

      test(
        '${shell.name}: a model the cache refuses is closed, not orphaned',
        () async {
          // `addCloseListener` is abstract on the published interface, so a
          // third-party model can throw from it. The shell built the model, so it
          // owns it until the cache accepts custody — dropping it here would
          // strand a live worker isolate nobody can reach, which is the very
          // failure this branch exists to end.
          final plugin = shell.create();
          backend.hostileListener = true;
          addTearDown(() => backend.hostileListener = false);

          await expectLater(
            plugin.createEmbeddingModel(
              modelPath: '/a.tflite',
              tokenizerPath: '/a.json',
            ),
            throwsStateError,
            reason: 'the refusal belongs to the caller',
          );

          expect(
            backend.lastModel?.closed,
            isTrue,
            reason: 'a model the cache cannot track must not be left open',
          );
          expect(plugin.initializedEmbeddingModel, isNull);
        },
      );

      test('${shell.name}: a failed build leaves no baseline behind', () async {
        final plugin = shell.create();
        addTearDown(() => plugin.initializedEmbeddingModel?.close());
        backend.failNext = true;

        await expectLater(
          plugin.createEmbeddingModel(
            modelPath: '/a.tflite',
            tokenizerPath: '/a.json',
          ),
          throwsStateError,
        );

        // The retry must be a fresh decision, not a replay of the failure: it
        // completes rather than rethrowing, and it reaches the backend again.
        await plugin.createEmbeddingModel(
          modelPath: '/a.tflite',
          tokenizerPath: '/a.json',
        );
        expect(backend.seenModelPaths, ['/a.tflite', '/a.tflite']);
      });
    }

    test('desktop names the call, not whatever embedder is active', () async {
      // The label only differs when an UNRELATED embedder is installed. It
      // names the call rather than whatever is active — the shell's own reuse
      // log is new in this branch, and an earlier revision of it read the name
      // off the active spec, which would have reported another model's name to
      // a caller who passed explicit paths.
      final plugin = FlutterEdgeAiDesktop.instance;
      addTearDown(() => plugin.initializedEmbeddingModel?.close());
      // `FlutterEdgeAiDesktop.instance` is a process singleton and its manager
      // holds the active spec in memory, which `setUp`'s mock preferences do
      // not reach. Without this, every later desktop test in this file inherits
      // an active embedder it never asked for.
      addTearDown(plugin.modelManager.clearModelCache);
      // The other half. Activation also persists the identity, and
      // `clearModelCache` only clears the in-memory field — so a later case
      // building a fresh manager could read back an active embedder it never
      // asked for.
      addTearDown(plugin.modelManager.clearActiveEmbeddingIdentity);
      await (plugin.modelManager as MobileModelManager).activateInstalledModel(
        EmbeddingModelSpec(
          name: 'unrelated-active-embedder',
          modelSource: ModelSource.file('/other.tflite'),
          tokenizerSource: ModelSource.file('/other.json'),
        ),
      );

      await plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/a.json',
      );
      // The second call is the one that logs a label, on the reuse branch.
      await plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/a.json',
      );

      final reuse = printed.where((l) => l.contains('Reusing existing'));
      expect(reuse, isNotEmpty, reason: 'the second call must have reused');
      expect(
        reuse.join('\n'),
        allOf(
          contains('explicit paths'),
          isNot(contains('unrelated-active-embedder')),
        ),
      );
    });

    test('a different tokenizer alone is also a different embedder', () async {
      final plugin = FlutterEdgeAiMobile();
      await plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/sentencepiece.model',
      );
      await plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/wordpiece.json',
      );
      expect(
        backend.seenModelPaths.length,
        2,
        reason:
            'same model, different tokenizer convention — different vectors',
      );
    });
  });

  test('a backend that embeddings DO use stays quiet', () async {
    await expectLater(
      FlutterEdgeAiMobile().createEmbeddingModel(
        preferredBackend: PreferredBackend.cpu,
      ),
      throwsStateError,
    );
    expect(notices(), isEmpty);
  });
}

/// The two shells a VM test can construct. Web is absent because
/// `FlutterEdgeAiWeb` needs `dart:js_interop`; its wiring is covered by the same
/// shared cache and by the web integration suites.
final _shells = <({String name, FlutterEdgeAiPlugin Function() create})>[
  (name: 'mobile', create: FlutterEdgeAiMobile.new),
  (name: 'desktop', create: () => FlutterEdgeAiDesktop.instance),
];

/// Counts how many times the shell actually asked for a model to be built, and
/// with which path — the only way to tell "reused" from "rebuilt" from outside.
class _CountingBackend implements EmbeddingBackendProvider {
  final List<String> seenModelPaths = [];

  /// When set, `createModel` waits on it — the window a second caller needs to
  /// arrive while the first build is still running.
  Completer<void>? gate;

  /// Fails exactly one build, to check the shell forgets it rather than
  /// remembering a model it never got.
  bool failNext = false;

  /// Builds a model that refuses a close listener, the way a third-party
  /// implementation not mixing in `CloseNotifier` might.
  bool hostileListener = false;

  /// The last model handed out, so a test can ask whether the shell closed it.
  _InertEmbeddingModel? lastModel;

  @override
  String get name => 'counting';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingModel> createModel(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    seenModelPaths.add(config.modelPath);
    if (gate != null) await gate!.future;
    if (failNext) {
      failNext = false;
      throw StateError('backend refused to build');
    }
    return lastModel = hostileListener
        ? _HostileListenerModel()
        : _InertEmbeddingModel();
  }
}

/// Refuses to register a close listener, so the cache cannot take custody.
class _HostileListenerModel extends _InertEmbeddingModel {
  @override
  void addCloseListener(void Function() listener) =>
      throw StateError('this model does not support close listeners');
}

class _InertEmbeddingModel extends EmbeddingModel with CloseNotifier {
  bool closed = false;

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async => const [0.0];

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async => const [
    [0.0],
  ];

  @override
  Future<int> getDimension() async => 1;

  @override
  Future<void> close() async {
    closed = true;
    fireCloseListeners();
  }
}
