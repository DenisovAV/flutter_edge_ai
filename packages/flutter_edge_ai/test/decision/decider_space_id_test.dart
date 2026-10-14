// The embedding-space id of a decider: what names the weights (installed file
// names and, where core can read them, sizes — or the caller's embedderId),
// the dimension, the backend, the image budget of a decider fitted on images,
// and the task prefix. A model that does not report its backend needs an
// embedderId.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/decision/embedding_decider.dart'
    show deciderSpaceId;
import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_host.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/embedding/shell_fixture.dart';
import 'core_embedder_fixture.dart';
import 'fake_embedder.dart';

final class _Host implements EmbeddingHost {
  @override
  EmbeddingPassInfo get info => const EmbeddingPassInfo(dimension: 3);

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async =>
      tableVectors[input.text]!;

  @override
  Future<String> get unexpectedExit => Completer<String>().future;

  @override
  Future<void> close() async {}
}

/// Serves text and PNG images, reporting [budget] tokens per image.
final class _VisionHost implements EmbeddingHost {
  _VisionHost(this.budget);

  final int? budget;

  @override
  EmbeddingPassInfo get info => EmbeddingPassInfo(
    dimension: 3,
    modalities: const {EmbeddingModality.text, EmbeddingModality.image},
    imageFormats: {EncodedMediaFormat.png},
    visionTokensPerImage: budget,
  );

  @override
  Set<EmbeddingModality> get modalities => const {
    EmbeddingModality.text,
    EmbeddingModality.image,
  };

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async =>
      input.text == null ? const [0, 0, 1] : tableVectors[input.text]!;

  @override
  Future<String> get unexpectedExit => Completer<String>().future;

  @override
  Future<void> close() async {}
}

/// A PNG signature, enough for core's format sniffing.
final _png = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  0,
  0,
  0,
]);

/// Option a has a photo among its examples.
List<DeciderOption> _imageOptions() => [
  DeciderOption(
    'a',
    examples: [EmbeddingInput.text('a1'), EmbeddingInput.image(_png)],
  ),
  DeciderOption(
    'b',
    examples: [EmbeddingInput.text('b1'), EmbeddingInput.text('b2')],
  ),
];

List<DeciderOption> _options() => [
  DeciderOption(
    'a',
    examples: [EmbeddingInput.text('a1'), EmbeddingInput.text('a2')],
  ),
  DeciderOption(
    'b',
    examples: [EmbeddingInput.text('b1'), EmbeddingInput.text('b2')],
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the identity', () {
    test('installed files: names and byte sizes, escaped', () {
      final model = CommonEmbeddingModel.withHost(
        _Host(),
        activeBackend: PreferredBackend.npu,
        installedFiles: [
          (name: 'eg2+npu@2.litertlm', bytes: 1234),
          (name: 'tok;en.json', bytes: null),
        ],
      );
      expect(
        deciderSpaceId(model),
        'model=eg2%2Bnpu%402.litertlm@1234+tok%3Ben.json;dim=3;backend=npu;'
        'prefix=task: classification | query: ',
      );
    });

    test('embedderId replaces the installed files', () {
      final model = CommonEmbeddingModel.withHost(
        _Host(),
        activeBackend: PreferredBackend.cpu,
        installedFiles: [(name: 'eg2.litertlm', bytes: 1234)],
      );
      expect(
        deciderSpaceId(model, embedderId: 'eg2@v1'),
        'model=eg2%40v1;dim=3;backend=cpu;prefix=task: classification | query: ',
      );
    });

    test('a model that does not report its backend needs an embedderId', () {
      final model = CommonEmbeddingModel.withHost(
        _Host(),
        installedFiles: [(name: 'eg1.tflite', bytes: 10)],
      );
      expect(
        () => deciderSpaceId(model),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'embedderId')
              .having((e) => '${e.message}', 'message', contains('backend')),
        ),
      );
    });

    test('the dimension and the backend are part of it; an empty '
        'embedderId is refused', () {
      final cpu = FakeEmbedder(
        dimension: 3,
        table: tableVectors,
        activeBackend: PreferredBackend.cpu,
      );
      expect(
        deciderSpaceId(cpu, embedderId: 'm'),
        'model=m;dim=3;backend=cpu;prefix=task: classification | query: ',
      );
      expect(() => deciderSpaceId(cpu, embedderId: ''), throwsArgumentError);
    });

    test('the image budget joins the id of a decider fitted on images, '
        'and only then', () {
      CommonEmbeddingModel model(int? budget) => CommonEmbeddingModel.withHost(
        _VisionHost(budget),
        activeBackend: PreferredBackend.cpu,
        installedFiles: [(name: 'eg2.litertlm', bytes: 1234)],
      );
      expect(
        deciderSpaceId(model(140), images: true),
        'model=eg2.litertlm@1234;dim=3;backend=cpu;vision=140;'
        'prefix=task: classification | query: ',
      );
      expect(deciderSpaceId(model(70), images: true), contains(';vision=70;'));
      expect(deciderSpaceId(model(140)), isNot(contains('vision')));
      expect(
        deciderSpaceId(model(null), images: true),
        isNot(contains('vision')),
        reason: 'an engine without a budget setting has nothing to add',
      );
      expect(
        deciderSpaceId(model(140), embedderId: 'eg2-440m', images: true),
        contains(';vision=140;'),
        reason: 'the budget is the embedder\'s, not part of the caller\'s id',
      );
    });

    test('an image among the labelled requests binds the decider to the '
        'budget too', () async {
      final model = CommonEmbeddingModel.withHost(
        _VisionHost(140),
        activeBackend: PreferredBackend.cpu,
        installedFiles: [(name: 'eg2.litertlm', bytes: 1234)],
      );
      final decider = await model.createDecider(
        options: _options(),
        calibration: DeciderCalibration.fromLabelled([
          (input: EmbeddingInput.text('about a'), optionId: 'a'),
          (input: EmbeddingInput.text('about b'), optionId: 'b'),
          // A wrong row keeps the temperature off the grid's end.
          (input: EmbeddingInput.text('about a'), optionId: 'b'),
          (input: EmbeddingInput.image(_png), optionId: 'a'),
        ], maxError: 0.5),
      );
      final artifact = decider.toArtifact();
      expect(artifact['spaceId'], contains(';vision=140;'));
      expect(artifact['imageInputs'], isTrue);
    });

    test('with an embedderId, a model without a backend gets no backend '
        'term: the id names the space', () {
      final embedder = FakeEmbedder(dimension: 3, table: tableVectors);
      final id = deciderSpaceId(embedder, embedderId: 'litert-js-webgpu');
      expect(
        id,
        'model=litert-js-webgpu;dim=3;prefix=task: classification | query: ',
      );
      expect(id, isNot(contains('unknown')));
    });
  });

  group('on an embedder a shell built', () {
    final fixture = ShellFixture();
    final plugins = <FlutterEdgeAiPlugin>[];

    setUp(() async {
      await fixture.setUp();
      EmbeddingRegistry.instance
        ..reset()
        ..registerAll([TableBackend()]);
    });

    tearDown(() async {
      for (final plugin in plugins) {
        await plugin.initializedEmbeddingModel?.close();
      }
      plugins.clear();
      await fixture.tearDown();
      EmbeddingRegistry.instance.reset();
    });

    for (final shell in shells) {
      test('${shell.name}: the sizes of the installed files are in the id; '
          'new weights under the same name are another space', () async {
        final plugin = shell.create();
        plugins.add(plugin);
        await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
        final first = await plugin.createEmbeddingModel();
        final decider = await first.createDecider(
          options: _options(),
          calibration: const DeciderCalibration.none(),
        );
        final artifact = decider.toArtifact();
        expect(artifact['spaceId'], contains('m.tflite@${1024 * 1024 + 16}'));
        expect(artifact['spaceId'], contains('@2048'));

        // Same file name, other bytes.
        File(
          fixture.modelPath('m.tflite'),
        ).writeAsBytesSync(Uint8List(1024 * 1024 + 32));
        await first.close();
        final second = await plugin.createEmbeddingModel();
        await expectLater(
          second.loadDecider(artifact),
          throwsA(isA<DeciderSpaceMismatchException>()),
        );
      });

      test('${shell.name}: a decider fitted on an image is bound to the '
          'image budget; one fitted on text is not', () async {
        EmbeddingRegistry.instance
          ..reset()
          ..registerAll([TableBackend(visionTokensPerImage: 140)]);
        final plugin = shell.create();
        plugins.add(plugin);
        await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
        final at140 = await plugin.createEmbeddingModel(supportImage: true);
        final imageArtifact = (await at140.createDecider(
          options: _imageOptions(),
          calibration: const DeciderCalibration.none(),
        )).toArtifact();
        final textArtifact = (await at140.createDecider(
          options: _options(),
          calibration: const DeciderCalibration.none(),
        )).toArtifact();
        expect(imageArtifact['spaceId'], contains(';vision=140;'));
        expect(imageArtifact['imageInputs'], isTrue);
        expect(textArtifact['spaceId'], isNot(contains('vision')));
        expect(textArtifact.containsKey('imageInputs'), isFalse);
        // Round trip on the same embedder keeps the flag and the space.
        final reloaded = (await at140.loadDecider(imageArtifact)).toArtifact();
        expect(reloaded['spaceId'], imageArtifact['spaceId']);
        expect(reloaded['imageInputs'], isTrue);

        // The app now registers the engine at 70 tokens per image.
        await at140.close();
        EmbeddingRegistry.instance
          ..reset()
          ..registerAll([TableBackend(visionTokensPerImage: 70)]);
        final at70 = await plugin.createEmbeddingModel(supportImage: true);
        await expectLater(
          at70.loadDecider(imageArtifact),
          throwsA(
            isA<DeciderSpaceMismatchException>()
                .having((e) => e.expected, 'expected', contains('vision=140'))
                .having((e) => e.actual, 'actual', contains('vision=70')),
          ),
        );
        final text = await at70.loadDecider(textArtifact);
        expect(
          (await text.choose(
            DeciderInput(EmbeddingInput.text('about b')),
          )).choice,
          'b',
        );
      });

      test('${shell.name}: core\'s replacement at another image budget is '
          'another space for an image-fitted decider only', () async {
        EmbeddingRegistry.instance
          ..reset()
          ..registerAll([TableBackend(visionTokensPerImage: 140)]);
        final plugin = shell.create();
        plugins.add(plugin);
        await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
        final at140 = await plugin.createEmbeddingModel(supportImage: true);
        final imageDecider = await at140.createDecider(
          options: _imageOptions(),
          calibration: const DeciderCalibration.none(),
        );
        final textDecider = await at140.createDecider(
          options: _options(),
          calibration: const DeciderCalibration.none(),
        );

        // The app closes the embedder; the next choose re-resolves through
        // core, which now builds at 70 tokens per image.
        await at140.close();
        EmbeddingRegistry.instance
          ..reset()
          ..registerAll([TableBackend(visionTokensPerImage: 70)]);
        await expectLater(
          imageDecider.choose(DeciderInput(EmbeddingInput.text('about a'))),
          throwsA(
            isA<DeciderSpaceMismatchException>()
                .having((e) => e.expected, 'expected', contains('vision=140'))
                .having((e) => e.actual, 'actual', contains('vision=70')),
          ),
        );
        expect(
          (await textDecider.choose(
            DeciderInput(EmbeddingInput.text('about b')),
          )).choice,
          'b',
        );
      });
    }
  });
}
