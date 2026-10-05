import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_gemma/src/flutter_gemma_embedder.dart';

import 'src/fake_runtime.dart';

void main() {
  late FakeRuntime runtime;
  late FakeEmbeddingModel fakeEmbedder;

  setUp(() {
    fakeEmbedder = FakeEmbeddingModel();
    runtime = FakeRuntime(embedder: fakeEmbedder);
  });

  Embedder buildEmbedder() {
    return createFlutterGemmaEmbedder(
      name: 'flutter-gemma/embedding-gemma-300m',
      runtime: runtime,
    );
  }

  group('createFlutterGemmaEmbedder', () {
    test('generates embedding for single document', () async {
      fakeEmbedder.embeddingsToReturn = [
        [0.1, 0.2, 0.3],
      ];

      final embedder = buildEmbedder();
      final response = await embedder(
        EmbedRequest(
          input: [
            DocumentData(
              content: [TextPart(text: 'Hello world')],
            ),
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

      expect(response.embeddings.first.metadata, {
        'source': 'test',
        'page': 1,
      });
    });

    test('caches embedding model across calls', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0],
      ];

      final embedder = buildEmbedder();

      await embedder(EmbedRequest(
        input: [DocumentData(content: [TextPart(text: 'a')])],
      ));
      await embedder(EmbedRequest(
        input: [DocumentData(content: [TextPart(text: 'b')])],
      ));

      expect(runtime.getActiveEmbedderCallCount, 1);
      expect(fakeEmbedder.generateEmbeddingsCallCount, 2);
    });

    test('joins multiple text parts in document', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0],
      ];

      final embedder = buildEmbedder();
      await embedder(
        EmbedRequest(
          input: [
            DocumentData(content: [
              TextPart(text: 'Hello'),
              TextPart(text: 'world'),
            ]),
          ],
        ),
      );

      expect(fakeEmbedder.lastTexts, ['Hello world']);
    });

    test('throws on null request', () async {
      final embedder = buildEmbedder();

      await expectLater(
        embedder(null),
        throwsA(isA<GenkitException>()),
      );
    });

    test('passes preferredBackend to runtime', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0],
      ];

      final embedder = buildEmbedder();
      await embedder(EmbedRequest(
        input: [DocumentData(content: [TextPart(text: 'test')])],
        options: {'preferredBackend': 'gpu'},
      ));

      expect(runtime.lastPreferredBackend, gemma.PreferredBackend.gpu);
    });

    test('invalidates cache when preferredBackend changes', () async {
      fakeEmbedder.embeddingsToReturn = [
        [1.0],
      ];

      final embedder = buildEmbedder();

      await embedder(EmbedRequest(
        input: [DocumentData(content: [TextPart(text: 'a')])],
        options: {'preferredBackend': 'cpu'},
      ));
      await embedder(EmbedRequest(
        input: [DocumentData(content: [TextPart(text: 'b')])],
        options: {'preferredBackend': 'gpu'},
      ));

      expect(runtime.getActiveEmbedderCallCount, 2);
    });

    test('throws on unknown preferredBackend', () async {
      final embedder = buildEmbedder();

      await expectLater(
        embedder(EmbedRequest(
          input: [DocumentData(content: [TextPart(text: 'test')])],
          options: {'preferredBackend': 'tpu'},
        )),
        throwsA(isA<GenkitException>()),
      );
    });
  });
}
