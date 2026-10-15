// A decider on an embedder core built survives core replacing that embedder:
// its next choose takes core's active embedder through the shell's own entry
// point (the cache's cover rule decides reuse) and, when the space id is the
// same, retries there. Another space fails with
// DeciderSpaceMismatchException. A model core did not build is never
// replaced: its EmbedderClosedException arrives unchanged.
//
// The shells, the EmbedderCache and the worker isolate are real; only the
// backend's pass is a table (core_embedder_fixture.dart).

import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/embedding/shell_fixture.dart';
import 'core_embedder_fixture.dart';
import 'fake_embedder.dart';

EmbeddingInput _t(String text) => EmbeddingInput.text(text);
DeciderInput _in(String text) => DeciderInput(_t(text));

List<DeciderOption> _options() => [
  DeciderOption('a', examples: [_t('a1'), _t('a2')]),
  DeciderOption('b', examples: [_t('b1'), _t('b2')]),
];

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  FlutterEdgeAiPlugin create(FlutterEdgeAiPlugin Function() factory) {
    final plugin = factory();
    plugins.add(plugin);
    return plugin;
  }

  for (final shell in shells) {
    test('${shell.name}: core widens the embedder for images; the decider '
        'takes the widened one and answers', () async {
      final plugin = create(shell.create);
      await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
      final textOnly = await plugin.createEmbeddingModel();
      final decider = await textOnly.createDecider(
        options: _options(),
        calibration: const DeciderCalibration.none(),
      );

      // Another part of the app asks for images: the cache closes the
      // text-only embedder and builds one with both.
      final widened = await plugin.createEmbeddingModel(supportImage: true);
      expect(textOnly.isClosed, isTrue);
      expect(decider.isClosed, isFalse, reason: 'it can take the new one');

      final answer = await decider.choose(_in('about a'));
      expect(answer.choice, 'a');
      expect(
        identical(plugin.initializedEmbeddingModel, widened),
        isTrue,
        reason: 'the cover rule reused the widened embedder: no rebuild',
      );
      expect(widened.isClosed, isFalse);
      expect(
        decider.capabilities.modalities,
        contains(EmbeddingModality.image),
      );
      // And it now embeds what the widened model serves.
      final image = await decider.choose(
        DeciderInput(EmbeddingInput.image(_png)),
      );
      expect(image.ranked, isNotEmpty);
    });

    test('${shell.name}: an embedder closed with nothing cached is rebuilt '
        'with the media it served', () async {
      final plugin = create(shell.create);
      await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
      final withImages = await plugin.createEmbeddingModel(supportImage: true);
      final decider = await withImages.createDecider(
        options: _options(),
        calibration: const DeciderCalibration.none(),
      );
      // The app closes it (a worker that died leaves the cache the same way).
      await withImages.close();
      final image = await decider.choose(
        DeciderInput(EmbeddingInput.image(_png)),
      );
      expect(image.ranked, isNotEmpty);
      expect(plugin.initializedEmbeddingModel?.isClosed, isFalse);
    });

    test('${shell.name}: a decider loaded from an artifact takes the '
        'replacement too', () async {
      final plugin = create(shell.create);
      await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
      final first = await plugin.createEmbeddingModel();
      final artifact = (await first.createDecider(
        options: _options(),
        calibration: const DeciderCalibration.none(),
      )).toArtifact();
      final loaded = await first.loadDecider(artifact);
      await plugin.createEmbeddingModel(supportImage: true);
      expect((await loaded.choose(_in('about b'))).choice, 'b');
    });

    test('${shell.name}: another active model is another space: '
        'DeciderSpaceMismatchException, not an answer', () async {
      final plugin = create(shell.create);
      await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
      final first = await plugin.createEmbeddingModel();
      final decider = await first.createDecider(
        options: _options(),
        calibration: const DeciderCalibration.none(),
      );
      await fixture.activate(plugin, model: 'n.tflite', tokenizer: 'n.json');
      await plugin.createEmbeddingModel();
      expect(first.isClosed, isTrue);
      await expectLater(
        decider.choose(_in('about a')),
        throwsA(
          isA<DeciderSpaceMismatchException>()
              .having((e) => e.expected, 'expected', contains('m.tflite'))
              .having((e) => e.actual, 'actual', contains('n.tflite')),
        ),
      );
    });

    test('${shell.name}: an empty among on a replaced embedder takes the '
        'replacement instead of failing', () async {
      final plugin = create(shell.create);
      await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
      final first = await plugin.createEmbeddingModel();
      final decider = await first.createDecider(
        options: _options(),
        calibration: const DeciderCalibration.none(),
      );
      await plugin.createEmbeddingModel(supportImage: true);
      final answer = await decider.choose(_in('about a'), among: const []);
      expect(answer.abstainReason, AbstainReason.noCandidates);
    });

    test('${shell.name}: Decider.chooseAll moves every decider of the '
        'replaced embedder to the new one', () async {
      final plugin = create(shell.create);
      await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
      final first = await plugin.createEmbeddingModel();
      final one = await first.createDecider(
        options: _options(),
        calibration: const DeciderCalibration.none(),
      );
      final two = await first.createDecider(
        options: _options().reversed.toList(),
        calibration: const DeciderCalibration.none(),
      );
      await plugin.createEmbeddingModel(supportImage: true);
      final answers = await Decider.chooseAll(_in('about b'), [one, two]);
      expect(answers.map((a) => a.choice), ['b', 'b']);
      expect(one.isClosed, isFalse);
      expect(two.isClosed, isFalse);
    });
  }

  for (final shell in shells) {
    test('${shell.name}: in Decider.chooseAll, a decider whose space the new '
        'embedder is not is refused, not scored with its vector', () async {
      final plugin = create(shell.create);
      await fixture.activate(plugin, model: 'm.tflite', tokenizer: 'm.json');
      final first = await plugin.createEmbeddingModel();
      // Named by the caller: survives another model under the same id.
      final named = await first.createDecider(
        options: _options(),
        calibration: const DeciderCalibration.none(),
        embedderId: 'table-v1',
      );
      // Named by the installed files: another model is another space.
      final byFiles = await first.createDecider(
        options: _options(),
        calibration: const DeciderCalibration.none(),
      );
      await fixture.activate(plugin, model: 'n.tflite', tokenizer: 'n.json');
      await plugin.createEmbeddingModel();
      await expectLater(
        Decider.chooseAll(_in('about a'), [named, byFiles]),
        throwsA(isA<DeciderSpaceMismatchException>()),
      );
      expect((await named.choose(_in('about a'))).choice, 'a');
    });
  }

  test('a model core did not build is not replaced: EmbedderClosedException '
      'arrives unchanged and the decider reports closed', () async {
    final embedder = FakeEmbedder(dimension: 3, table: tableVectors);
    final decider = await embedder.createDecider(
      options: _options(),
      calibration: const DeciderCalibration.none(),
      embedderId: 'fake',
    );
    await embedder.close();
    expect(decider.isClosed, isTrue);
    await expectLater(
      decider.choose(_in('about a')),
      throwsA(isA<EmbedderClosedException>()),
    );
  });
}
