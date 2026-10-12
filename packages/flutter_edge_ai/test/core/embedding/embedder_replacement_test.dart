// `createEmbeddingModel` on the two shells a VM test can construct: a new
// embedder is never built while the one it replaces is still closing, so two
// native models are never resident at once. Web is absent because
// `FlutterEdgeAiWeb` needs `dart:js_interop`; it uses the same `EmbedderCache`
// through the same `loadActiveEmbedder`.
//
// The backend describes a pass that core hosts in its worker isolate. The pass
// reports its load and close over a SendPort, and a gated close waits for the
// test to release it — the only way to hold a close open across the isolate.
//
// Run: flutter test test/core/embedding/embedder_replacement_test.dart

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixture = ShellFixture();
  late _PassEvents events;
  late _GatedBackend backend;
  final plugins = <FlutterEdgeAiPlugin>[];

  setUp(() async {
    await fixture.setUp();
    EmbeddingRegistry.instance.reset();
    events = _PassEvents();
    backend = _GatedBackend(events.sendPort);
    EmbeddingRegistry.instance.registerAll([backend]);
  });

  tearDown(() async {
    // Every close from here on completes at once, so nothing hangs.
    events.autoRelease();
    for (final plugin in plugins) {
      await plugin.initializedEmbeddingModel?.close();
    }
    plugins.clear();
    await fixture.tearDown();
    EmbeddingRegistry.instance.reset();
    events.dispose();
  });

  FlutterEdgeAiPlugin create(FlutterEdgeAiPlugin Function() factory) {
    final plugin = factory();
    plugins.add(plugin);
    return plugin;
  }

  /// Long enough for a build that is wrongly NOT waiting to have spawned its
  /// worker and loaded.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 300));

  for (final shell in shells) {
    test('${shell.name}: a replacement is not built until the embedder it '
        'replaces has finished closing', () async {
      final plugin = create(shell.create);
      final a = fixture.modelPath('a.tflite');
      final b = fixture.modelPath('b.tflite');

      await fixture.activate(plugin, model: 'a.tflite', tokenizer: 'a.json');
      await plugin.createEmbeddingModel();
      await fixture.activate(plugin, model: 'b.tflite', tokenizer: 'b.json');
      final second = plugin.createEmbeddingModel();

      await events.until(() => events.closing.contains(a));
      await settle();
      expect(events.loads, [
        a,
      ], reason: 'b must not be built while a is still closing');

      events.releaseAll();
      await second;
      expect(events.loads, [a, b]);
      expect(events.closing.where((p) => p == a), hasLength(1));
    });

    test('${shell.name}: an embedder the app closed without awaiting is not '
        'rebuilt until its close has finished', () async {
      // `isClosed` is true from the moment close() is called. Taking that
      // alone as "gone" built the replacement while the app's own close was
      // still freeing the old native model.
      final plugin = create(shell.create);
      final a = fixture.modelPath('a.tflite');

      await fixture.activate(plugin, model: 'a.tflite', tokenizer: 'a.json');
      final first = await plugin.createEmbeddingModel();
      unawaited(first.close());

      final again = plugin.createEmbeddingModel();
      await events.until(() => events.closing.contains(a));
      await settle();
      expect(events.loads, [
        a,
      ], reason: 'the app\'s close of the first one is still running');

      events.releaseAll();
      final rebuilt = await again;
      expect(events.loads, [a, a]);
      expect(identical(rebuilt, first), isFalse);
      expect(events.closing, [
        a,
      ], reason: 'the shell joined the app\'s close rather than run another');
    });
  }
}

/// What the passes report from core's worker isolates: every load and every
/// close, by model path. A gated close waits until [releaseAll].
final class _PassEvents {
  _PassEvents() {
    _port.listen((message) {
      switch (message) {
        case ('load', final String path):
          loads.add(path);
        case ('closing', final String path, final SendPort release):
          closing.add(path);
          if (_autoRelease) {
            release.send(null);
          } else {
            _held.add(release);
          }
      }
    });
  }

  final _port = ReceivePort();
  final _held = <SendPort>[];
  bool _autoRelease = false;

  /// Model paths, in the order their passes loaded.
  final loads = <String>[];

  /// Model paths, in the order their passes started closing.
  final closing = <String>[];

  SendPort get sendPort => _port.sendPort;

  /// Lets every close that is waiting finish.
  void releaseAll() {
    for (final release in _held) {
      release.send(null);
    }
    _held.clear();
  }

  /// From now on no close waits.
  void autoRelease() {
    _autoRelease = true;
    releaseAll();
  }

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out; loads $loads, closing $closing');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void dispose() => _port.close();
}

/// Describes, for every spec, a pass whose close waits for the test.
final class _GatedBackend extends EmbeddingBackendProvider {
  _GatedBackend(this._events);

  final SendPort _events;

  @override
  String get name => 'gated';

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async => EmbeddingPassDescriptor<_GatedConfig>(
    engineTag: 'Gated',
    factory: _buildGatedPass,
    config: _GatedConfig(config.modelPath, _events),
    activeBackend: PreferredBackend.cpu,
  );
}

final class _GatedConfig {
  const _GatedConfig(this.modelPath, this.events);
  final String modelPath;
  final SendPort events;
}

EmbeddingPass _buildGatedPass(_GatedConfig config) => _GatedPass(config);

/// Runs in core's worker isolate.
final class _GatedPass extends EmbeddingPass {
  _GatedPass(this._config);

  final _GatedConfig _config;

  @override
  Future<EmbeddingPassInfo> load() async {
    _config.events.send(('load', _config.modelPath));
    return const EmbeddingPassInfo(dimension: 1);
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async =>
      const [1.0];

  @override
  Future<void> close() async {
    final release = ReceivePort();
    _config.events.send(('closing', _config.modelPath, release.sendPort));
    await release.first;
    release.close();
  }
}
