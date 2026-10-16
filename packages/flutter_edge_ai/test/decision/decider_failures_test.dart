// Failures name what they belong to: an option input that cannot be embedded
// names its option and input; an empty `among` still refuses a closed
// embedder or an input it cannot embed instead of answering "no candidates".

import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

final _table = <String, List<double>>{
  'option a': [1, 0.2, 0],
  'a1': [1, 0, 0],
  'a2': [0.9, 0.1, 0],
  'b1': [0, 1, 0],
  'b2': [0.1, 0.9, 0],
  'about a': [1, 0.05, 0],
  'nan': [double.nan, 0, 0],
};

EmbeddingInput _t(String text) => EmbeddingInput.text(text);

List<DeciderOption> _options() => [
  DeciderOption('a', description: 'option a', examples: [_t('a1'), _t('a2')]),
  DeciderOption('b', examples: [_t('b1'), _t('b2')]),
];

void main() {
  group('an option input that fails names its option and input', () {
    test('an engine failure keeps its type and fields', () async {
      final embedder = FakeEmbedder(dimension: 3, table: _table)
        ..onEmbed = (input) {
          if (input.text == 'b2') {
            throw const EmbeddingInputTooLongException(
              'too long',
              maxInputTokens: 1024,
              actualTokens: 2000,
            );
          }
        };
      await expectLater(
        embedder.createDecider(options: _options(), embedderId: 'fake'),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.message, 'message', contains('Option "b"'))
              .having((e) => e.message, 'message', contains('example 1'))
              .having((e) => e.message, 'message', contains('too long'))
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having((e) => e.actualTokens, 'actualTokens', 2000),
        ),
      );
    });

    test('the description is named as such', () async {
      final embedder = FakeEmbedder(dimension: 3, table: _table)
        ..onEmbed = (input) {
          if (input.text == 'option a') {
            throw const EmbeddingEngineException('boom', engine: 'Fake');
          }
        };
      await expectLater(
        embedder.createDecider(options: _options(), embedderId: 'fake'),
        throwsA(
          isA<EmbeddingEngineException>()
              .having(
                (e) => e.message,
                'message',
                contains('Option "a", its description'),
              )
              .having((e) => e.engine, 'engine', 'Fake'),
        ),
      );
    });

    test('a vector that is not finite names its input', () async {
      final embedder = FakeEmbedder(dimension: 3, table: _table);
      await expectLater(
        embedder.createDecider(
          options: [
            DeciderOption('a', examples: [_t('a1'), _t('nan')]),
            DeciderOption('b', examples: [_t('b1'), _t('b2')]),
          ],
          embedderId: 'fake',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Option "a", example 1'),
          ),
        ),
      );
    });

    test('an input the model cannot embed is refused before anything is '
        'embedded', () async {
      final embedder = FakeEmbedder(dimension: 3, table: _table);
      await expectLater(
        embedder.createDecider(
          options: [
            DeciderOption('a', examples: [_t('a1'), _t('a2')]),
            DeciderOption(
              'b',
              examples: [
                _t('b1'),
                EmbeddingInput.image(Uint8List.fromList(const [1, 2])),
              ],
            ),
          ],
          embedderId: 'fake',
        ),
        throwsA(
          isA<EmbeddingModalityNotLoadedException>().having(
            (e) => e.message,
            'message',
            contains('Option "b", example 1'),
          ),
        ),
      );
      expect(embedder.calls, isEmpty);
    });
  });

  group('an empty among', () {
    test('on a closed embedder fails as every choose does', () async {
      final embedder = FakeEmbedder(dimension: 3, table: _table);
      final decider = await embedder.createDecider(
        options: _options(),
        calibration: const EmbeddingDeciderCalibration.none(),
        embedderId: 'fake',
      );
      await embedder.close();
      await expectLater(
        decider.choose(DeciderInput(_t('about a')), among: const []),
        throwsA(isA<EmbedderClosedException>()),
      );
    });

    test('with an input the model cannot embed fails as every choose '
        'does', () async {
      final embedder = FakeEmbedder(dimension: 3, table: _table);
      final decider = await embedder.createDecider(
        options: _options(),
        calibration: const EmbeddingDeciderCalibration.none(),
        embedderId: 'fake',
      );
      await expectLater(
        decider.choose(
          DeciderInput(EmbeddingInput.image(Uint8List.fromList(const [1]))),
          among: const [],
        ),
        throwsA(isA<EmbeddingModalityNotLoadedException>()),
      );
    });
  });
}
