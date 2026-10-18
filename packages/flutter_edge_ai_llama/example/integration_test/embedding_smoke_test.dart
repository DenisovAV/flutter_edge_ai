import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _modelPath = String.fromEnvironment('GGUF_EMBEDDING_MODEL_PATH');
const _modelUrl = String.fromEnvironment('GGUF_EMBEDDING_MODEL_URL');
const _requested = String.fromEnvironment(
  'GGUF_EMBEDDING_BACKEND',
  defaultValue: 'cpu',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'packaged GGUF text embeddings rank, reject overflow, cancel and reload',
    (tester) async {
      expect(
        _modelPath.isNotEmpty || _modelUrl.isNotEmpty,
        isTrue,
        reason: 'Supply the pinned EmbeddingGemma 2 GGUF fixture.',
      );
      expect(['cpu', 'gpu', 'auto'], contains(_requested));
      final backend = switch (_requested) {
        'cpu' => edge.PreferredBackend.cpu,
        'gpu' => edge.PreferredBackend.gpu,
        _ => null,
      };
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await edge.FlutterEdgeAi.initialize(
        embeddingBackends: const [LlamaEmbeddingBackend()],
      );
      final builder = edge.FlutterEdgeAi.installEmbedder();
      final installation =
          await (_modelPath.isNotEmpty
                  ? builder.modelFromFile(_modelPath)
                  : builder.modelFromNetwork(
                      _modelUrl,
                      filename: 'embeddinggemma-2-Q8_0.gguf',
                    ))
              .install();
      expect(installation.spec.files, hasLength(1));
      expect(installation.spec.tokenizerSource, isNull);
      edge.EmbeddingModel? loaded;
      addTearDown(() async => loaded?.close());
      for (var cycle = 0; cycle < 3; cycle++) {
        final model = await edge.FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: backend,
        );
        loaded = model;
        expect(
          model.dimension,
          768,
          reason: 'EG2 output projection, not its 512-wide transformer',
        );
        expect(model.maxInputTokens, 1024);
        expect(model.modalities, {edge.EmbeddingModality.text});
        if (backend != null) expect(model.activeBackend, backend);
        expect(
          await edge.FlutterEdgeAi.getActiveEmbedder(preferredBackend: backend),
          same(model),
        );

        final query = await model.embed(
          edge.EmbeddingInput.text('How can I brew a cup of coffee?'),
          taskType: edge.TaskType.retrievalQuery,
        );
        final documents = await model.embedAll([
          edge.EmbeddingInput.text(
            'Brew coffee by pouring hot water over ground coffee beans in a filter.',
          ),
          edge.EmbeddingInput.text(
            'Neptune takes about 165 years to complete its orbit around the Sun.',
          ),
        ], taskType: edge.TaskType.retrievalDocument);
        for (final vector in [query, ...documents]) {
          _checkVector(vector);
        }
        final related = _dot(query, documents[0]);
        final unrelated = _dot(query, documents[1]);
        expect(related, greaterThan(unrelated));
        debugPrint(
          'GGUF embedding cycle=$cycle backend=${model.activeBackend} dimension=${model.dimension} related=$related unrelated=$unrelated',
        );

        if (cycle == 0) {
          for (final task in edge.TaskType.values) {
            _checkVector(
              await model.embed(
                edge.EmbeddingInput.text('A short document about coffee.'),
                taskType: task,
              ),
            );
          }
          await expectLater(
            model.embed(
              edge.EmbeddingInput.text('coffee ' * 2200),
              taskType: edge.TaskType.retrievalDocument,
            ),
            throwsA(
              isA<edge.EmbeddingInputTooLongException>()
                  .having((e) => e.maxInputTokens, 'effective limit', 1024)
                  .having(
                    (e) => e.actualTokens,
                    'exact count',
                    greaterThan(1024),
                  ),
            ),
          );
          final token = edge.CancelToken();
          final cancelled = model.embedAll(
            List.generate(
              32,
              (_) => edge.EmbeddingInput.text('A cup of coffee.'),
            ),
            taskType: edge.TaskType.retrievalDocument,
            cancelToken: token,
          );
          final timer = Timer(const Duration(milliseconds: 1), token.cancel);
          await expectLater(
            cancelled,
            throwsA(isA<edge.EmbeddingCancelledException>()),
          );
          timer.cancel();
          _checkVector(
            await model.embed(
              edge.EmbeddingInput.text('Still usable.'),
              taskType: edge.TaskType.none,
            ),
          );
          await expectLater(
            edge.FlutterEdgeAi.getActiveEmbedder(
              supportImage: true,
              preferredBackend: backend,
            ),
            throwsA(isA<edge.EmbeddingLoadException>()),
          );
          expect(
            await edge.FlutterEdgeAi.getActiveEmbedder(
              preferredBackend: backend,
            ),
            same(model),
          );
        }
        await model.close();
        await model.close();
        expect(model.isClosed, isTrue);
        await expectLater(
          model.embed(
            edge.EmbeddingInput.text('closed'),
            taskType: edge.TaskType.none,
          ),
          throwsA(isA<edge.EmbedderClosedException>()),
        );
      }
      if (_requested == 'gpu') {
        final cpu = await edge.FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: edge.PreferredBackend.cpu,
        );
        loaded = cpu;
        expect(cpu.activeBackend, edge.PreferredBackend.cpu);
        final cpuVector = await cpu.embed(
          edge.EmbeddingInput.text('Coffee retrieval.'),
          taskType: edge.TaskType.retrievalQuery,
        );
        final gpu = await edge.FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: edge.PreferredBackend.gpu,
        );
        loaded = gpu;
        expect(cpu.isClosed, isTrue);
        expect(gpu, isNot(same(cpu)));
        expect(gpu.activeBackend, edge.PreferredBackend.gpu);
        final gpuVector = await gpu.embed(
          edge.EmbeddingInput.text('Coffee retrieval.'),
          taskType: edge.TaskType.retrievalQuery,
        );
        final parity = _dot(cpuVector, gpuVector);
        expect(parity, greaterThan(0.999));
        debugPrint('GGUF embedding CPU/Metal cosine=$parity');
        final automatic = await edge.FlutterEdgeAi.getActiveEmbedder();
        loaded = automatic;
        expect(gpu.isClosed, isTrue);
        expect(automatic, isNot(same(gpu)));
        _checkVector(
          await automatic.embed(
            edge.EmbeddingInput.text('Automatic backend.'),
            taskType: edge.TaskType.none,
          ),
        );
        await automatic.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _checkVector(List<double> vector) {
  expect(vector, hasLength(768));
  expect(vector.every((v) => v.isFinite), isTrue);
  expect(math.sqrt(_dot(vector, vector)), closeTo(1, 0.001));
}

double _dot(List<double> a, List<double> b) =>
    List.generate(a.length, (i) => a[i] * b[i]).fold(0.0, (sum, v) => sum + v);
