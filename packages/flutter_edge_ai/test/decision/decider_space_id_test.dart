// The embedding-space id of a decider: what names the weights (installed file
// names and, where core can read them, sizes — or the caller's embedderId),
// the dimension, the backend and the task prefix. A model that does not
// report its backend needs an embedderId.

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
    }
  });
}
