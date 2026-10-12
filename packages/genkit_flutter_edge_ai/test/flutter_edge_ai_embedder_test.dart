import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_edge_ai/src/flutter_edge_ai_embedder.dart';

import 'src/fake_runtime.dart';

void main() {
  late FakeRuntime runtime;
  late FakeEmbeddingModel fakeEmbedder;

  setUp(() {
    fakeEmbedder = FakeEmbeddingModel();
    runtime = FakeRuntime(embedder: fakeEmbedder);
  });

  Embedder buildEmbedder() {
    return createFlutterEdgeAiEmbedder(
      name: 'flutter-edge-ai/embedding-gemma-300m',
      runtime: runtime,
    );
  }

  group('createFlutterEdgeAiEmbedder', () {
    test('generates embedding for single document', () async {
      fakeEmbedder.embeddingsToReturn = [
        [0.1, 0.2, 0.3],
      ];

      final embedder = buildEmbedder();
      final response = await embedder(
        EmbedRequest(
          input: [
            DocumentData(content: [TextPart(text: 'Hello world')]),
          ],
        ),
      );

      expect(response.embeddings, hasLength(1));
      expect(response.embeddings.first.embedding, [0.1, 0.2, 0.3]);
      expect(fakeEmbedder.lastTexts, ['Hello world']);
    });

    test('generates embeddings for batch of documents', () async {
      fakeEmbedder.embeddingsToReturn = [
        [0.1, 0.2],
        [0.4, 0.5],
        [0.7, 0.8],
      ];

      final embedder = buildEmbedder();
      final response = await embedder(
        EmbedRequest(
          input: [
            DocumentData(content: [TextPart(text: 'First')]),
            DocumentData(content: [TextPart(text: 'Second')]),
            DocumentData(content: [TextPart(text: 'Third')]),
          ],
        ),
      );

      expect(response.embeddings, hasLength(3));
      expect(response.embeddings[0].embedding, [0.1, 0.2]);
      expect(response.embeddings[1].embedding, [0.4, 0.5]);
      expect(response.embeddings[2].embedding, [0.7, 0.8]);
      expect(fakeEmbedder.lastTexts, ['First', 'Second', 'Third']);
    });

    test('preserves document metadata in embedding results', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0, 2.0],
      ];

      final embedder = buildEmbedder();
      final response = await embedder(
        EmbedRequest(
          input: [
            DocumentData(
              content: [TextPart(text: 'Hello')],
              metadata: {'source': 'test', 'page': 1},
            ),
          ],
        ),
      );

      expect(response.embeddings.first.metadata, {'source': 'test', 'page': 1});
    });

    test('asks flutter_edge_ai for the embedder on every call, which reuses '
        'it', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0],
      ];

      final embedder = buildEmbedder();

      await embedder(
        EmbedRequest(
          input: [
            DocumentData(content: [TextPart(text: 'a')]),
          ],
        ),
      );
      await embedder(
        EmbedRequest(
          input: [
            DocumentData(content: [TextPart(text: 'b')]),
          ],
        ),
      );

      // flutter_edge_ai keeps the loaded embedder and builds a new one when
      // the active embedder changes; a handle cached here would miss that.
      expect(runtime.getActiveEmbedderCallCount, 2);
      expect(fakeEmbedder.embedAllCallCount, 2);
    });

    test('vectors are identical to 0.8.0\'s for the same input: the query '
        'task generateEmbeddings defaulted to', () async {
      final model = FakeEmbeddingModel(
        vectorFor: (text, taskType) => [
          text.length.toDouble(),
          taskType.index.toDouble(),
        ],
      );
      runtime = FakeRuntime(embedder: model);
      final texts = ['First text', 'Second'];

      final response = await buildEmbedder()(
        EmbedRequest(
          input: [
            for (final t in texts) DocumentData(content: [TextPart(text: t)]),
          ],
        ),
      );

      // What 0.8.0 called: the deprecated forwarder, with its default task.
      // ignore: deprecated_member_use
      final before = await model.generateEmbeddings(texts);
      expect([for (final e in response.embeddings) e.embedding], before);
      expect(model.lastTaskType, gemma.TaskType.retrievalQuery);
    });

    test('a model closed before the request ran is resolved again and the '
        'request retried once', () async {
      final closed = FakeEmbeddingModel()..closed = true;
      final fresh = FakeEmbeddingModel()
        ..embeddingsToReturn = [
          [0.5, 0.5],
        ];
      runtime = FakeRuntime(embedder: fresh)..embedderQueue.add(closed);

      final response = await buildEmbedder()(
        EmbedRequest(
          input: [
            DocumentData(content: [TextPart(text: 'a')]),
          ],
        ),
      );

      expect(response.embeddings.single.embedding, [0.5, 0.5]);
      expect(runtime.getActiveEmbedderCallCount, 2);
    });

    test(
      'retries only once: a second closed model fails the request',
      () async {
        final first = FakeEmbeddingModel()..closed = true;
        final second = FakeEmbeddingModel()..closed = true;
        runtime = FakeRuntime(embedder: second)..embedderQueue.add(first);

        await expectLater(
          buildEmbedder()(
            EmbedRequest(
              input: [
                DocumentData(content: [TextPart(text: 'a')]),
              ],
            ),
          ),
          throwsA(isA<gemma.EmbedderClosedException>()),
        );
        expect(runtime.getActiveEmbedderCallCount, 2);
      },
    );

    test('any other failure is not retried', () async {
      fakeEmbedder.failWith = const gemma.EmbeddingEngineException(
        'boom',
        engine: 'Fake',
      );

      await expectLater(
        buildEmbedder()(
          EmbedRequest(
            input: [
              DocumentData(content: [TextPart(text: 'a')]),
            ],
          ),
        ),
        throwsA(isA<gemma.EmbeddingEngineException>()),
      );
      expect(runtime.getActiveEmbedderCallCount, 1);
    });

    test('joins multiple text parts in document', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0],
      ];

      final embedder = buildEmbedder();
      await embedder(
        EmbedRequest(
          input: [
            DocumentData(
              content: [
                TextPart(text: 'Hello'),
                TextPart(text: 'world'),
              ],
            ),
          ],
        ),
      );

      expect(fakeEmbedder.lastTexts, ['Hello world']);
    });

    test('throws on null request', () async {
      final embedder = buildEmbedder();

      await expectLater(embedder(null), throwsA(isA<GenkitException>()));
    });

    test('passes preferredBackend to runtime', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0],
      ];

      final embedder = buildEmbedder();
      await embedder(
        EmbedRequest(
          input: [
            DocumentData(content: [TextPart(text: 'test')]),
          ],
          options: {'preferredBackend': 'gpu'},
        ),
      );

      expect(runtime.lastPreferredBackend, gemma.PreferredBackend.gpu);
    });

    test('each request passes its own preferredBackend', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0],
      ];

      final embedder = buildEmbedder();

      await embedder(
        EmbedRequest(
          input: [
            DocumentData(content: [TextPart(text: 'a')]),
          ],
          options: {'preferredBackend': 'cpu'},
        ),
      );
      await embedder(
        EmbedRequest(
          input: [
            DocumentData(content: [TextPart(text: 'b')]),
          ],
          options: {'preferredBackend': 'gpu'},
        ),
      );

      expect(runtime.getActiveEmbedderCallCount, 2);
    });

    test('throws on unknown preferredBackend', () async {
      final embedder = buildEmbedder();

      await expectLater(
        embedder(
          EmbedRequest(
            input: [
              DocumentData(content: [TextPart(text: 'test')]),
            ],
            options: {'preferredBackend': 'tpu'},
          ),
        ),
        throwsA(isA<GenkitException>()),
      );
    });

    test('an option of the wrong type is INVALID_ARGUMENT', () async {
      final embedder = buildEmbedder();

      await expectLater(
        embedder(
          EmbedRequest(
            input: [
              DocumentData(content: [TextPart(text: 'test')]),
            ],
            options: {'preferredBackend': 42},
          ),
        ),
        throwsA(
          isA<GenkitException>().having(
            (e) => e.status,
            'status',
            StatusCode.invalidArgument,
          ),
        ),
      );
    });
  });
}
