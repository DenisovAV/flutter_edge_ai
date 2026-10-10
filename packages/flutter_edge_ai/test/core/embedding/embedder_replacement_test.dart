// `createEmbeddingModel` on the two shells a VM test can construct: a new
// embedder is never built while the one it replaces is still closing, so two
// native models are never resident at once. Web is absent because
// `FlutterEdgeAiWeb` needs `dart:js_interop`; it uses the same `EmbedderCache`.
//
// Run: flutter test test/core/embedding/embedder_replacement_test.dart

import 'dart:async';

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

  late _CountingBackend backend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmbeddingRegistry.instance.reset();
    backend = _CountingBackend();
    EmbeddingRegistry.instance.registerAll([backend]);
  });

  tearDown(() => EmbeddingRegistry.instance.reset());

  for (final shell in _shells) {
    test('${shell.name}: a replacement is not built until the embedder it '
        'replaces has finished closing', () async {
      final plugin = shell.create();
      addTearDown(() => plugin.initializedEmbeddingModel?.close());
      final closeGate = Completer<void>();
      backend.closeGate = closeGate;
      // Registered after the close above, so it runs first: a failed
      // expectation must not leave that close waiting on a shut gate.
      addTearDown(() {
        if (!closeGate.isCompleted) closeGate.complete();
      });

      final first = await plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/a.json',
      );
      final second = plugin.createEmbeddingModel(
        modelPath: '/b.tflite',
        tokenizerPath: '/b.json',
      );
      await pumpEventQueue();

      expect((first as _GatedCloseModel).teardowns, 1);
      expect(backend.builds, [
        '/a.tflite',
      ], reason: '/b must not be built while /a is still closing');

      closeGate.complete();
      await second;
      expect(backend.builds, ['/a.tflite', '/b.tflite']);
    });

    test('${shell.name}: an embedder the app closed without awaiting is not '
        'rebuilt until its close has finished', () async {
      // `isClosed` is true from the moment close() is called. Taking that
      // alone as "gone" built the replacement while the app's own close was
      // still freeing the old native model.
      final plugin = shell.create();
      addTearDown(() => plugin.initializedEmbeddingModel?.close());
      final closeGate = Completer<void>();
      backend.closeGate = closeGate;
      // Registered after the close above, so it runs first: a failed
      // expectation must not leave that close waiting on a shut gate.
      addTearDown(() {
        if (!closeGate.isCompleted) closeGate.complete();
      });

      final first = await plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/a.json',
      );
      unawaited(first.close());

      final again = plugin.createEmbeddingModel(
        modelPath: '/a.tflite',
        tokenizerPath: '/a.json',
      );
      await pumpEventQueue();
      expect(backend.builds, [
        '/a.tflite',
      ], reason: 'the app\'s close of the first /a is still running');

      closeGate.complete();
      final rebuilt = await again;
      expect(backend.builds, ['/a.tflite', '/a.tflite']);
      expect(identical(rebuilt, first), isFalse);
      expect(
        (first as _GatedCloseModel).teardowns,
        1,
        reason: 'the shell joined the app\'s close rather than run another',
      );
    });
  }
}

final _shells = <({String name, FlutterEdgeAiPlugin Function() create})>[
  (name: 'mobile', create: FlutterEdgeAiMobile.new),
  (name: 'desktop', create: () => FlutterEdgeAiDesktop.instance),
];

/// Records every model path the shell asks it to build.
class _CountingBackend implements EmbeddingBackendProvider {
  final List<String> builds = [];

  /// When set, each built model's teardown waits on it.
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
    builds.add(config.modelPath);
    return _GatedCloseModel(closeGate);
  }
}

/// Closes the way `CommonEmbeddingModel` does: closed at once, torn down when
/// the gate opens, and every `close()` call returns the same teardown.
class _GatedCloseModel extends EmbeddingModel with CloseNotifier {
  _GatedCloseModel(this._closeGate);

  final Completer<void>? _closeGate;
  Future<void>? _teardown;
  bool _closed = false;
  int teardowns = 0;

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
  Future<void> close() => _teardown ??= _close();

  Future<void> _close() async {
    _closed = true;
    teardowns++;
    final gate = _closeGate;
    if (gate != null) await gate.future;
    fireCloseListeners();
  }
}
