// The shells' embedder path (R5 §4.2, §5.5, §10.1 "Shells"), driven through
// the real mobile and desktop shells over an installed ACTIVE embedder — since
// 2.3.0 there are no explicit paths. Covers what the backend is handed
// (RuntimeConfig: a null tokenizer path for a self-contained spec, the media
// flags, widened on a rebuild), the describe() path through core's own host,
// and the reuse / rebuild / concurrency rules each shell must keep by wrapping
// its entry point in EmbedderCache.serialize.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/src/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixture = ShellFixture();

  setUp(() async {
    await fixture.setUp();
    EmbeddingRegistry.instance.reset();
  });

  tearDown(() async {
    await fixture.tearDown();
    EmbeddingRegistry.instance.reset();
  });

  group('what the backend is handed', () {
    for (final shell in shells) {
      test(
        '${shell.name}: a self-contained spec gets a null tokenizer path',
        () async {
          final backend = _DescribingBackend();
          EmbeddingRegistry.instance.registerAll([backend]);
          final plugin = shell.create();

          await fixture.activate(plugin, model: 'eg2.litertlm');
          final model = await plugin.createEmbeddingModel();

          final config = backend.configs.single;
          expect(config.modelPath, fixture.modelPath('eg2.litertlm'));
          expect(config.tokenizerPath, isNull, reason: 'never the model path');
          expect(model.dimension, 3);
          await model.close();
        },
      );

      test('${shell.name}: a two-file spec gets its tokenizer path', () async {
        final backend = _DescribingBackend();
        EmbeddingRegistry.instance.registerAll([backend]);
        final plugin = shell.create();

        await fixture.activate(plugin, model: 'm.tflite', tokenizer: 't.json');
        await plugin.createEmbeddingModel();

        expect(backend.configs.single.tokenizerPath, endsWith('t.json'));
      });

      test(
        '${shell.name}: declared media reach the backend and the model',
        () async {
          final backend = _DescribingBackend(imageCapable: true);
          EmbeddingRegistry.instance.registerAll([backend]);
          final plugin = shell.create();

          await fixture.activate(plugin, model: 'eg2.litertlm');
          final model = await plugin.createEmbeddingModel(supportImage: true);

          expect(backend.configs.single.supportImage, isTrue);
          expect(backend.configs.single.supportAudio, isFalse);
          expect(model.modalities, {
            EmbeddingModality.text,
            EmbeddingModality.image,
          });
        },
      );

      test('${shell.name}: a text-only request reuses an image-capable '
          'embedder; a new medium rebuilds with the union', () async {
        final backend = _DescribingBackend(imageCapable: true);
        EmbeddingRegistry.instance.registerAll([backend]);
        final plugin = shell.create();

        await fixture.activate(plugin, model: 'eg2.litertlm');
        final image = await plugin.createEmbeddingModel(supportImage: true);
        final text = await plugin.createEmbeddingModel();
        expect(identical(image, text), isTrue);

        await expectLater(
          plugin.createEmbeddingModel(supportAudio: true),
          throwsA(
            isA<EmbeddingLoadException>().having(
              (e) => e.message,
              'message',
              contains('audio'),
            ),
          ),
          reason: 'the fake has no audio tower, and says so at load',
        );
        expect(backend.configs.last.supportImage, isTrue, reason: 'widened');
        expect(backend.configs.last.supportAudio, isTrue);
        expect(image.isClosed, isTrue, reason: 'one engine at a time');
      });
    }
  });

  group('describe() runs before the cached embedder is closed', () {
    for (final shell in shells) {
      test('${shell.name}: a refused wider rebuild keeps the text embedder, '
          'which then serves text without a rebuild', () async {
        final backend = _DescribingBackend(
          refuseWhen: (config) => config.supportImage,
        );
        EmbeddingRegistry.instance.registerAll([backend]);
        final plugin = shell.create();
        await fixture.activate(plugin, model: 'eg2.litertlm');

        final text = await plugin.createEmbeddingModel();
        await expectLater(
          plugin.createEmbeddingModel(supportImage: true),
          throwsA(isA<EmbeddingLoadException>()),
        );
        expect(
          text.isClosed,
          isFalse,
          reason: 'describe() refused before anything was closed',
        );
        expect(plugin.initializedEmbeddingModel, same(text));

        final again = await plugin.createEmbeddingModel();
        expect(again, same(text), reason: 'no rebuild');
        expect(backend.configs, hasLength(2), reason: 'not described again');
        await text.close();
      });

      test(
        '${shell.name}: a refused new identity keeps the old embedder',
        () async {
          final backend = _DescribingBackend(
            refuseWhen: (config) => config.modelPath.endsWith('b.litertlm'),
          );
          EmbeddingRegistry.instance.registerAll([backend]);
          final plugin = shell.create();
          await fixture.activate(plugin, model: 'a.litertlm');
          final old = await plugin.createEmbeddingModel();

          await fixture.activate(plugin, model: 'b.litertlm');
          await expectLater(
            plugin.createEmbeddingModel(),
            throwsA(isA<EmbeddingLoadException>()),
          );
          expect(old.isClosed, isFalse);
          expect(plugin.initializedEmbeddingModel, same(old));
          await old.close();
        },
      );
    }
    test('the union keeps media the request did not repeat, and the cache '
        'remembers it', () async {
      final backend = _DescribingBackend(
        imageCapable: true,
        audioCapable: true,
      );
      EmbeddingRegistry.instance.registerAll([backend]);
      final plugin = FlutterEdgeAiMobile();
      await fixture.activate(plugin, model: 'eg2.litertlm');

      await plugin.createEmbeddingModel(supportAudio: true);
      final both = await plugin.createEmbeddingModel(supportImage: true);
      expect(backend.configs, hasLength(2));
      expect(backend.configs.last.supportImage, isTrue);
      expect(
        backend.configs.last.supportAudio,
        isTrue,
        reason: 'audio was loaded before; a rebuild never narrows',
      );
      expect(both.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
        EmbeddingModality.audio,
      });

      // Each medium alone is now served by the widened embedder.
      expect(await plugin.createEmbeddingModel(supportAudio: true), same(both));
      expect(await plugin.createEmbeddingModel(supportImage: true), same(both));
      expect(backend.configs, hasLength(2), reason: 'no third build');
    });

    test('the describe() path hosts the engine pass: requests reach it, '
        'validated, with the task prefix decision left to the pass', () async {
      EmbeddingRegistry.instance.registerAll([_DescribingBackend()]);
      final plugin = FlutterEdgeAiMobile();

      await fixture.activate(plugin, model: 'eg2.litertlm');
      final model = await plugin.createEmbeddingModel(
        preferredBackend: PreferredBackend.gpu,
      );

      expect(model.activeBackend, PreferredBackend.cpu);
      expect(model.maxInputTokens, 64);
      expect(
        await model.embed(
          EmbeddingInput.text('abc'),
          taskType: TaskType.factChecking,
        ),
        [TaskType.factChecking.index.toDouble(), 3, 1],
      );
      await expectLater(
        model.embed(
          EmbeddingInput.image(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
          taskType: TaskType.none,
        ),
        throwsA(isA<EmbeddingModalityNotLoadedException>()),
      );
      await model.close();
    });

    test('a pass still closing after its failed load holds the next build '
        '(never two engines resident)', () async {
      final gate = '${Directory.systemTemp.createTempSync('gate').path}/open';
      final backend = _DescribingBackend(failLoadGate: gate);
      EmbeddingRegistry.instance.registerAll([backend]);
      final plugin = FlutterEdgeAiMobile();
      await fixture.activate(plugin, model: 'eg2.litertlm');
      addTearDown(() {
        if (!File(gate).existsSync()) File(gate).writeAsStringSync('');
      });

      await expectLater(
        plugin.createEmbeddingModel(),
        throwsA(isA<EmbeddingLoadException>()),
      );
      while (!File('$gate.closing').existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final retry = plugin.createEmbeddingModel();
      retry.ignore();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        backend.configs,
        hasLength(1),
        reason: 'the retry must wait for the failed pass to close',
      );

      File(gate).writeAsStringSync('');
      await expectLater(retry, throwsA(isA<EmbeddingLoadException>()));
      expect(backend.configs, hasLength(2));
    });

    test('a backend that refuses in describe() fails the load, typed, and '
        'leaves nothing cached', () async {
      final backend = _DescribingBackend(refuse: true);
      EmbeddingRegistry.instance.registerAll([backend]);
      final plugin = FlutterEdgeAiMobile();

      await fixture.activate(plugin, model: 'eg2.litertlm');
      await expectLater(
        plugin.createEmbeddingModel(supportImage: true),
        throwsA(isA<EmbeddingLoadException>()),
      );
      expect(plugin.initializedEmbeddingModel, isNull);
    });

    test('whatever describe() throws reaches the app as a load failure, its '
        'cause kept', () async {
      final boom = StateError('describe blew up');
      EmbeddingRegistry.instance.registerAll([
        _DescribingBackend(describeThrows: boom),
      ]);
      final plugin = FlutterEdgeAiMobile();
      await fixture.activate(plugin, model: 'eg2.litertlm');
      await expectLater(
        plugin.createEmbeddingModel(),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'Describing')
              .having((e) => e.cause, 'cause', same(boom))
              .having(
                (e) => e.message,
                'message',
                contains('describe blew up'),
              ),
        ),
      );
    });

    test('no backend that can run the spec is a StateError', () async {
      EmbeddingRegistry.instance.registerAll([
        _DescribingBackend(handles: false),
      ]);
      final plugin = FlutterEdgeAiMobile();
      await fixture.activate(plugin, model: 'eg2.litertlm');
      await expectLater(plugin.createEmbeddingModel(), throwsStateError);
    });
  });

  group('an embedder cached for one backend never serves the other', () {
    for (final shell in shells) {
      test('${shell.name}: an embedder with no NPU path asked for npu runs on '
          'CPU, says so once, and reports cpu', () async {
        final backend = _DescribingBackend();
        EmbeddingRegistry.instance.registerAll([backend]);
        final plugin = shell.create();
        await fixture.activate(plugin, model: 'a.tflite', tokenizer: 'a.json');
        resetEmbedderBackendNotice();
        final printed = <String>[];
        final original = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) printed.add(message);
        };
        try {
          final model = await plugin.createEmbeddingModel(
            preferredBackend: PreferredBackend.npu,
          );
          expect(model.activeBackend, PreferredBackend.cpu);
          expect(
            printed.where((l) => l.contains('npu is not applied')),
            hasLength(1),
          );
          await model.close();
        } finally {
          debugPrint = original;
          resetEmbedderBackendNotice();
        }
      });

      test(
        '${shell.name}: a CPU embedder is not handed to an npu request; '
        'the backend refuses it and the CPU embedder keeps serving',
        () async {
          // The generic EmbeddingGemma 2 bundle's rule: it has no NPU graph.
          final backend = _DescribingBackend(
            refuseWhen: (config) =>
                config.preferredBackend == PreferredBackend.npu,
          );
          EmbeddingRegistry.instance.registerAll([backend]);
          final plugin = shell.create();
          await fixture.activate(plugin, model: 'eg2.litertlm');

          final cpu = await plugin.createEmbeddingModel();
          await expectLater(
            plugin.createEmbeddingModel(preferredBackend: PreferredBackend.npu),
            throwsA(isA<EmbeddingLoadException>()),
          );
          expect(
            backend.configs,
            hasLength(2),
            reason: 'the npu request reached describe() instead of the cache',
          );
          expect(backend.configs.last.preferredBackend, PreferredBackend.npu);
          expect(cpu.isClosed, isFalse);
          expect(plugin.initializedEmbeddingModel, same(cpu));

          // gpu reaches no embedder: it is served by the CPU one, unasked.
          final gpu = await plugin.createEmbeddingModel(
            preferredBackend: PreferredBackend.gpu,
          );
          expect(gpu, same(cpu));
          expect(backend.configs, hasLength(2));
          await cpu.close();
        },
      );

      test(
        '${shell.name}: an NPU embedder is not handed to a request without '
        'npu; the backend refuses it and the NPU embedder keeps serving',
        () async {
          // A per-SoC bundle's rule: it runs on the NPU or not at all.
          final backend = _NpuOnlyBackend();
          EmbeddingRegistry.instance.registerAll([backend]);
          final plugin = shell.create();
          await fixture.activate(plugin, model: 'eg2_npu.litertlm');

          final npu = await plugin.createEmbeddingModel(
            preferredBackend: PreferredBackend.npu,
          );
          expect(npu.activeBackend, PreferredBackend.npu);
          for (final other in [
            null,
            PreferredBackend.cpu,
            PreferredBackend.gpu,
          ]) {
            await expectLater(
              plugin.createEmbeddingModel(preferredBackend: other),
              throwsA(isA<EmbeddingLoadException>()),
              reason: '$other',
            );
          }
          expect(backend.described, [
            PreferredBackend.npu,
            null,
            PreferredBackend.cpu,
            PreferredBackend.gpu,
          ]);
          expect(npu.isClosed, isFalse);
          final again = await plugin.createEmbeddingModel(
            preferredBackend: PreferredBackend.npu,
          );
          expect(again, same(npu), reason: 'the NPU embedder still serves npu');
          expect(backend.described, hasLength(4));
          await npu.close();
        },
      );
    }
  });

  group('reuse, rebuild and concurrency (each shell serialises its entry)', () {
    late _CountingBackend backend;

    setUp(() {
      backend = _CountingBackend();
      EmbeddingRegistry.instance.registerAll([backend]);
    });

    test('the same active model is reused; a different one rebuilds', () async {
      final plugin = FlutterEdgeAiMobile();
      await fixture.activate(plugin, model: 'a.tflite', tokenizer: 'a.json');
      final first = await plugin.createEmbeddingModel();
      final again = await plugin.createEmbeddingModel();
      expect(identical(first, again), isTrue);
      expect(backend.built, 1);

      await fixture.activate(plugin, model: 'b.tflite', tokenizer: 'b.json');
      final second = await plugin.createEmbeddingModel();
      expect(identical(first, second), isFalse);
      expect(backend.built, 2);
      expect(first.isClosed, isTrue);
      await second.close();
    });

    test('a different tokenizer alone is a different embedder', () async {
      final plugin = FlutterEdgeAiMobile();
      await fixture.activate(
        plugin,
        model: 'a.tflite',
        tokenizer: 'sentencepiece.model',
      );
      await plugin.createEmbeddingModel();
      await fixture.activate(
        plugin,
        model: 'a.tflite',
        tokenizer: 'wordpiece.json',
      );
      final second = await plugin.createEmbeddingModel();
      expect(backend.built, 2);
      await second.close();
    });

    for (final shell in shells) {
      test(
        '${shell.name}: two concurrent first calls build ONE embedder',
        () async {
          final plugin = shell.create();
          await fixture.activate(
            plugin,
            model: 'a.tflite',
            tokenizer: 'a.json',
          );
          backend.gate = Completer<void>();

          final a = plugin.createEmbeddingModel();
          await Future<void>.delayed(Duration.zero);
          final b = plugin.createEmbeddingModel();
          // Long enough for b to resolve its paths and reach the backend if
          // nothing held it; serialised, it waits behind a's build.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(
            backend.paths,
            hasLength(1),
            reason: 'b must wait in the lane, not start a second build',
          );
          backend.gate!.complete();
          final models = await Future.wait([a, b]);

          expect(backend.built, 1);
          expect(identical(models[0], models[1]), isTrue);
          await models[0].close();
        },
      );

      test('${shell.name}: a request for another model arriving mid-build is '
          'served its own model, and the superseded one is closed', () async {
        final plugin = shell.create();
        await fixture.activate(plugin, model: 'a.tflite', tokenizer: 'a.json');
        backend.gate = Completer<void>();

        final a = plugin.createEmbeddingModel();
        // Let a's request start and reach the backend before b is asked for.
        await pumpEventQueue();
        await fixture.activate(plugin, model: 'b.tflite', tokenizer: 'b.json');
        final b = plugin.createEmbeddingModel();

        backend.gate!.complete();
        final models = await Future.wait([a, b]);

        expect(backend.paths, [
          fixture.modelPath('a.tflite'),
          fixture.modelPath('b.tflite'),
        ]);
        expect(identical(models[0], models[1]), isFalse);
        expect(models[0].isClosed, isTrue, reason: 'b closed the superseded a');
        expect(plugin.initializedEmbeddingModel, same(models[1]));
        await models[1].close();
      });

      test('${shell.name}: a failed build leaves no baseline behind', () async {
        final plugin = shell.create();
        await fixture.activate(plugin, model: 'a.tflite', tokenizer: 'a.json');
        backend.failNext = true;

        await expectLater(
          plugin.createEmbeddingModel(),
          throwsA(isA<EmbeddingLoadException>()),
        );
        // The retry is a fresh decision, not a replay of the failure.
        final model = await plugin.createEmbeddingModel();
        expect(backend.paths, hasLength(2));
        await model.close();
      });
    }
  });
}

/// A backend that describes a pass core hosts in its worker isolate.
final class _DescribingBackend extends EmbeddingBackendProvider {
  _DescribingBackend({
    this.imageCapable = false,
    this.audioCapable = false,
    this.refuse = false,
    this.handles = true,
    this.failLoadGate,
    this.describeThrows,
    this.refuseWhen,
  });

  /// When set, describe() throws it — not an EmbeddingLoadException.
  final Object? describeThrows;

  /// describe() refuses (EmbeddingLoadException) the configs this matches.
  final bool Function(RuntimeConfig config)? refuseWhen;

  /// When set, the pass fails its load and its close waits until this file
  /// exists (the pass runs in the worker isolate, so a file is the gate).
  final String? failLoadGate;

  final bool imageCapable;
  final bool audioCapable;
  final bool refuse;
  final bool handles;
  final configs = <RuntimeConfig>[];

  @override
  String get name => 'Describing';

  @override
  bool canHandle(EmbeddingModelSpec spec) => handles;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    configs.add(config);
    final error = describeThrows;
    if (error != null) throw error;
    if (refuse || (refuseWhen?.call(config) ?? false)) {
      throw const EmbeddingLoadException(
        'this engine refuses media',
        engine: 'Describing',
      );
    }
    return EmbeddingPassDescriptor<_PassConfig>(
      engineTag: 'Describing',
      factory: _buildPass,
      config: _PassConfig(
        imageCapable: imageCapable,
        audioCapable: audioCapable,
        failLoadGate: failLoadGate,
      ),
      activeBackend: PreferredBackend.cpu,
    );
  }
}

final class _PassConfig {
  const _PassConfig({
    required this.imageCapable,
    required this.audioCapable,
    this.failLoadGate,
  });
  final bool imageCapable;
  final bool audioCapable;
  final String? failLoadGate;
}

EmbeddingPass _buildPass(_PassConfig config) => _Pass(config);

final class _Pass extends EmbeddingPass {
  _Pass(this._config);

  final _PassConfig _config;

  @override
  Future<EmbeddingPassInfo> load() async {
    if (_config.failLoadGate != null) throw StateError('load refused');
    return _info();
  }

  EmbeddingPassInfo _info() => EmbeddingPassInfo(
    dimension: 3,
    maxInputTokens: 64,
    modalities: {
      EmbeddingModality.text,
      if (_config.imageCapable) EmbeddingModality.image,
      if (_config.audioCapable) EmbeddingModality.audio,
    },
    imageFormats: _config.imageCapable ? {EncodedMediaFormat.jpeg} : const {},
    audioFormats: _config.audioCapable ? {EncodedMediaFormat.wav} : const {},
  );

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async => [
    taskType.index.toDouble(),
    (input.text ?? '').length.toDouble(),
    1,
  ];

  @override
  Future<void> close() async {
    final gate = _config.failLoadGate;
    if (gate == null) return;
    File('$gate.closing').writeAsStringSync('');
    while (!File(gate).existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}

/// A describing backend that counts what it describes. [gate] holds
/// describe() — which the loader runs inside the cache's lane — so a test can
/// see whether a second caller waits behind the first. [failNext] makes the
/// next describe() throw, a failure before anything is built.
final class _CountingBackend extends EmbeddingBackendProvider {
  /// How many descriptors this backend handed out (= embedders core built).
  int built = 0;
  final paths = <String>[];
  Completer<void>? gate;
  bool failNext = false;

  @override
  String get name => 'Counting';

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    paths.add(config.modelPath);
    if (gate != null) await gate!.future;
    if (failNext) {
      failNext = false;
      throw StateError('backend refused to build');
    }
    built++;
    return const EmbeddingPassDescriptor<_PassConfig>(
      engineTag: 'Counting',
      factory: _buildPass,
      config: _PassConfig(imageCapable: false, audioCapable: false),
      activeBackend: PreferredBackend.cpu,
    );
  }
}

/// A backend that runs only on the NPU and refuses every other request, as
/// the LiteRT-LM backend does for an EmbeddingGemma 2 per-SoC bundle.
final class _NpuOnlyBackend extends EmbeddingBackendProvider {
  final described = <PreferredBackend?>[];

  @override
  String get name => 'NpuOnly';

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    described.add(config.preferredBackend);
    if (config.preferredBackend != PreferredBackend.npu) {
      throw const EmbeddingLoadException(
        'compiled for an NPU; ask for PreferredBackend.npu',
        engine: 'NpuOnly',
      );
    }
    return const EmbeddingPassDescriptor<_PassConfig>(
      engineTag: 'NpuOnly',
      factory: _buildPass,
      config: _PassConfig(imageCapable: false, audioCapable: false),
      activeBackend: PreferredBackend.npu,
    );
  }
}
