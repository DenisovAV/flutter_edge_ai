// createDecider(onProgress:) counts the inputs it embeds — each option's
// description and examples, then the labelled rows — as (done, total).

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
  'about b': [0.05, 1, 0],
  'a or b': [1, 0.98, 0],
};

EmbeddingInput _t(String text) => EmbeddingInput.text(text);

void main() {
  test('from (0, total) to (total, total), one step per embedded input, '
      'labelled rows included', () async {
    final progress = <(int, int)>[];
    final embedder = FakeEmbedder(dimension: 3, table: _table);
    await embedder.createDecider(
      options: [
        DeciderOption(
          'a',
          description: 'option a',
          examples: [_t('a1'), _t('a2')],
        ),
        DeciderOption('b', examples: [_t('b1'), _t('b2')]),
      ],
      calibration: DeciderCalibration.fromLabelled([
        (input: _t('about a'), optionId: 'a'),
        (input: _t('about b'), optionId: 'b'),
        (input: _t('a or b'), optionId: 'b'),
      ], maxError: 0.4),
      embedderId: 'fake',
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(progress, [for (var i = 0; i <= 8; i++) (i, 8)]);
    expect(embedder.calls, hasLength(8));
  });

  test('a throw from onProgress fails the call', () async {
    final embedder = FakeEmbedder(dimension: 3, table: _table);
    await expectLater(
      embedder.createDecider(
        options: [
          DeciderOption('a', examples: [_t('a1'), _t('a2')]),
          DeciderOption('b', examples: [_t('b1'), _t('b2')]),
        ],
        embedderId: 'fake',
        onProgress: (done, total) {
          if (done == 2) throw StateError('progress bar gone');
        },
      ),
      throwsA(isA<StateError>()),
    );
  });
}
