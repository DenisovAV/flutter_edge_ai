// TaskType, EmbeddingInput and the EmbeddingException family (R5 §2.1).

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TaskType', () {
    test('the two 2.1 values keep their indices (persisted corpora)', () {
      expect(TaskType.retrievalQuery.index, 0);
      expect(TaskType.retrievalDocument.index, 1);
    });

    test('nine values, appended in R5 order', () {
      expect(TaskType.values, [
        TaskType.retrievalQuery,
        TaskType.retrievalDocument,
        TaskType.none,
        TaskType.questionAnswering,
        TaskType.factChecking,
        TaskType.codeRetrieval,
        TaskType.classification,
        TaskType.clustering,
        TaskType.sentenceSimilarity,
      ]);
    });

    test('prefixes are pinned verbatim', () {
      // google/embeddinggemma-2 config_sentence_transformers.json @914f7f89.
      // A changed byte here silently moves every vector of that task.
      expect(
        {for (final t in TaskType.values) t.name: t.prefix},
        {
          'retrievalQuery': 'task: search result | query: ',
          'retrievalDocument': 'title: none | text: ',
          'none': '',
          'questionAnswering': 'task: question answering | query: ',
          'factChecking': 'task: fact checking | query: ',
          'codeRetrieval': 'task: code retrieval | query: ',
          'classification': 'task: classification | query: ',
          'clustering': 'task: clustering | query: ',
          'sentenceSimilarity': 'task: sentence similarity | query: ',
        },
      );
    });
  });

  group('EmbeddingInput', () {
    test('text carries only text; empty text is valid', () {
      final input = EmbeddingInput.text('');
      expect(input.text, '');
      expect(input.images, isEmpty);
      expect(input.audio, isNull);
      expect(input.modalities, {EmbeddingModality.text});
    });

    test('image and audio carry only their part', () {
      final image = EmbeddingInput.image(Uint8List.fromList([1, 2, 3]));
      expect(image.text, isNull);
      expect(image.images.single, [1, 2, 3]);
      expect(image.modalities, {EmbeddingModality.image});

      final audio = EmbeddingInput.audio(Uint8List.fromList([4, 5]));
      expect(audio.audio, [4, 5]);
      expect(audio.images, isEmpty);
      expect(audio.modalities, {EmbeddingModality.audio});
    });

    test('empty media bytes are refused', () {
      expect(() => EmbeddingInput.image(Uint8List(0)), throwsArgumentError);
      expect(() => EmbeddingInput.audio(Uint8List(0)), throwsArgumentError);
    });

    test('bytes are copied at construction (D19)', () {
      final buffer = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      final view = Uint8List.sublistView(buffer, 2, 4);
      final input = EmbeddingInput.image(view);

      buffer[2] = 99;
      expect(input.images.single, [3, 4], reason: 'the caller kept a handle');
      expect(
        input.images.single.buffer.lengthInBytes,
        2,
        reason: 'a view would drag its whole backing buffer along when sent',
      );
    });

    test('lists, sets and bytes are read-only', () {
      final input = EmbeddingInput.image(Uint8List.fromList([1]));
      expect(() => input.images.add(Uint8List(1)), throwsUnsupportedError);
      expect(() => input.images.single[0] = 7, throwsUnsupportedError);
      expect(
        () => input.modalities.add(EmbeddingModality.text),
        throwsUnsupportedError,
      );
    });

    test('crosses an isolate intact', () async {
      final input = EmbeddingInput.image(Uint8List.fromList([9, 8, 7]));
      final echoed = await Isolate.run(() => input);
      expect(echoed.images.single, [9, 8, 7]);
      expect(echoed.modalities, {EmbeddingModality.image});
    });

    test('the combined-input helper keeps the 2.4.0 constructor rules', () {
      final combined = debugCombinedEmbeddingInput(
        text: 'a cat',
        images: [
          Uint8List.fromList([1]),
        ],
      );
      expect(combined.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });
      expect(() => debugCombinedEmbeddingInput(), throwsArgumentError);
      expect(
        () => debugCombinedEmbeddingInput(images: [Uint8List(0)]),
        throwsArgumentError,
      );
    });
  });

  group('EmbeddingException family', () {
    test('every type is an EmbeddingException and an Exception', () {
      final all = <EmbeddingException>[
        const EmbedderClosedException(),
        const EmbedderCloseTimeoutException('x', waited: Duration.zero),
        const EmbeddingModalityNotLoadedException(
          'x',
          modality: EmbeddingModality.image,
          loaded: {EmbeddingModality.text},
        ),
        const UnsupportedEmbeddingCombinationException(
          'x',
          requested: {EmbeddingModality.text, EmbeddingModality.image},
        ),
        // Not const: a const set cannot hold a class that overrides ==.
        EmbeddingFormatNotSupportedException(
          'x',
          modality: EmbeddingModality.image,
          detected: EncodedMediaFormat.heic,
          accepted: {EncodedMediaFormat.jpeg},
        ),
        const EmbeddingInputTooLongException('x', maxInputTokens: 8),
        const EmbeddingCancelledException(),
        const EmbeddingLoadException('x', engine: 'E'),
        const EmbeddingEngineException('x', engine: 'E', nativeCode: 3),
      ];
      expect(all, everyElement(isA<Exception>()));
      expect(all.map((e) => e.runtimeType).toSet(), hasLength(all.length));
    });

    test('default messages and toString', () {
      expect(
        const EmbedderClosedException().message,
        'The embedding model is closed.',
      );
      expect(
        const EmbeddingCancelledException().toString(),
        'EmbeddingCancelledException: embedAll was cancelled.',
      );
      expect(
        const EmbeddingEngineException(
          'boom',
          engine: 'E',
          cause: 'native',
        ).toString(),
        'EmbeddingEngineException: boom (cause: native)',
      );
    });

    test('actualTokens is optional (engines that cannot count)', () {
      const e = EmbeddingInputTooLongException('x', maxInputTokens: 1024);
      expect(e.maxInputTokens, 1024);
      expect(e.actualTokens, isNull);
    });
  });
}
