// `createEmbeddingModel` on the two shells a VM test can construct: the
// explicit-paths contract (both or neither), and that a replacement embedder is
// not built while the one it replaces is still closing.
//
// Web is absent for the reason `embedder_notice_wiring_test.dart` gives:
// `FlutterEdgeAiWeb` needs `dart:js_interop`. Its guard is the same
// `embedderPathPairError` call these cases pin down, and the rule itself is
// tested directly below.
//
// Run: flutter test test/core/embedding/create_embedding_model_paths_test.dart

import 'dart:async';

import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/embedding/embedder_cache.dart';
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/desktop/flutter_edge_ai_desktop.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('embedderPathPairError', () {
    test('both paths, or neither, is a whole pair', () {
      expect(embedderPathPairError('/a.tflite', '/a.json'), isNull);
      expect(embedderPathPairError(null, null), isNull);
    });

    test('one path alone names both parameters and the one that was given', () {
      final onlyModel = embedderPathPairError('/a.tflite', null);
      expect(onlyModel, isA<ArgumentError>());
      expect(
        onlyModel!.message,
        allOf(
          contains('modelPath'),
          contains('tokenizerPath'),
          contains('only modelPath was given'),
        ),
      );

      final onlyTokenizer = embedderPathPairError(null, '/a.json');
      expect(
        onlyTokenizer!.message,
        allOf(contains('modelPath'), contains('only tokenizerPath was given')),
      );
    });
  });

  late _CountingBackend backend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmbeddingRegistry.instance.reset();
    backend = _CountingBackend();
    EmbeddingRegistry.instance.registerAll([backend]);
  });

  tearDown(() => EmbeddingRegistry.instance.reset());

  for (final shell in _shells) {
    group('${shell.name}: a half-given pair of paths', () {
      // An unrelated embedder is ACTIVE in every case here, because that is
      // what made the old behaviour wrong rather than merely unhelpful: mobile
      // answered with the active embedder, desktop paired the caller's model
      // with the active spec's tokenizer.
      Future<FlutterEdgeAiPlugin> shellWithActiveEmbedder() async {
        final plugin = shell.create();
        addTearDown(() => plugin.initializedEmbeddingModel?.close());
        final manager = plugin.modelManager as MobileModelManager;
        // The desktop shell is a process singleton whose manager keeps the
        // active spec in memory and in preferences; leave neither behind.
        addTearDown(manager.clearModelCache);
        addTearDown(manager.clearActiveEmbeddingIdentity);
        await manager.activateInstalledModel(
          EmbeddingModelSpec(
            name: 'unrelated-active-embedder',
            modelSource: ModelSource.file('/other.tflite'),
            tokenizerSource: ModelSource.file('/other.json'),
          ),
        );
        return plugin;
      }

      test('modelPath alone is an ArgumentError, not the active embedder or '
          'a mixed pair', () async {
        final plugin = await shellWithActiveEmbedder();

        await expectLater(
          plugin.createEmbeddingModel(modelPath: '/a.tflite'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              allOf(contains('modelPath'), contains('tokenizerPath')),
            ),
          ),
        );
        expect(backend.builds, isEmpty, reason: 'nothing may be built');
        expect(plugin.initializedEmbeddingModel, isNull);
      });

      test('tokenizerPath alone is an ArgumentError too', () async {
        final plugin = await shellWithActiveEmbedder();

        await expectLater(
          plugin.createEmbeddingModel(tokenizerPath: '/a.json'),
          throwsArgumentError,
        );
        expect(backend.builds, isEmpty);
      });

      // No active embedder here: on mobile an explicit-paths call still checks
      // that the ACTIVE spec is installed, and this fake one is not. That
      // check is older than this fix and not what these cases are about.
      test('a whole pair still builds exactly what it names', () async {
        final plugin = shell.create();
        addTearDown(() => plugin.initializedEmbeddingModel?.close());

        await plugin.createEmbeddingModel(
          modelPath: '/a.tflite',
          tokenizerPath: '/a.json',
        );
        expect(backend.builds, [('/a.tflite', '/a.json')]);
      });
    });

    test('${shell.name}: a replacement is not built until the embedder it '
        'replaces has finished closing', () async {
      // Two native engines resident at once is what this rules out. The
      // worker's close now waits for the request in flight instead of killing
      // the isolate after five seconds, so the old model's teardown can take a
      // while — and the shell must sit it out.
      final plugin = shell.create();
      addTearDown(() => plugin.initializedEmbeddingModel?.close());
      final closeGate = Completer<void>();
      backend.closeGate = closeGate;

      final first = await plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/a.json',
      );
      final second = plugin.createEmbeddingModel(
        modelPath: '/b.tflite',
        tokenizerPath: '/b.json',
      );
      await pumpEventQueue();

      expect((first as _GatedCloseModel).closeStarted, isTrue);
      expect(backend.builds.map((b) => b.$1), [
        '/a.tflite',
      ], reason: '/b must not be built while /a is still closing');

      closeGate.complete();
      await second;
      expect(backend.builds.map((b) => b.$1), ['/a.tflite', '/b.tflite']);
    });
  }
}

final _shells = <({String name, FlutterEdgeAiPlugin Function() create})>[
  (name: 'mobile', create: FlutterEdgeAiMobile.new),
  (name: 'desktop', create: () => FlutterEdgeAiDesktop.instance),
];

/// Records every build the shell asks for, with the pair of paths it used.
class _CountingBackend implements EmbeddingBackendProvider {
  final List<(String, String?)> builds = [];

  /// When set, each built model's `close()` waits on it.
  Completer<void>? closeGate;

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
    builds.add((config.modelPath, config.tokenizerPath));
    return _GatedCloseModel(closeGate);
  }
}

class _GatedCloseModel extends EmbeddingModel with CloseNotifier {
  _GatedCloseModel(this._closeGate);

  final Completer<void>? _closeGate;
  bool closeStarted = false;
  bool _closed = false;

  @override
  bool get isClosed => _closed;

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
    if (_closed) return;
    _closed = true;
    closeStarted = true;
    final gate = _closeGate;
    if (gate != null) await gate.future;
    fireCloseListeners();
  }
}
