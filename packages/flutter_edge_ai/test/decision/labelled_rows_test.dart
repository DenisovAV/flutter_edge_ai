// DeciderCalibration.fromLabelled owns a copy of its rows, and a held-out row
// may not repeat any option input — examples or description.

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

final _table = <String, List<double>>{
  'a1': [1, 0, 0],
  'a2': [0.9, 0.1, 0],
  'b1': [0, 1, 0],
  'b2': [0.1, 0.9, 0],
  'about a': [1, 0.05, 0],
  'about b': [0.05, 1, 0],
  'a or b': [1, 0.98, 0],
  'option a': [1, 0.2, 0],
};

EmbeddingInput _t(String text) => EmbeddingInput.text(text);

List<DeciderOption> _options() => [
  DeciderOption('a', description: 'option a', examples: [_t('a1'), _t('a2')]),
  DeciderOption('b', examples: [_t('b1'), _t('b2')]),
];

void main() {
  test('the rows are copied when the calibration is made', () async {
    final rows = <({EmbeddingInput input, String optionId})>[
      (input: _t('about a'), optionId: 'a'),
      (input: _t('about b'), optionId: 'b'),
      (input: _t('a or b'), optionId: 'b'),
    ];
    final calibration = DeciderCalibration.fromLabelled(rows, maxError: 0.4);
    // The caller's list changes while the decider embeds the options: before
    // the copy, rows were read before and after that await, so the labels
    // and the vectors no longer lined up.
    final embedder = FakeEmbedder(dimension: 3, table: _table)
      ..onEmbed = (input) {
        if (input.text == 'b2') rows.removeLast();
      };
    final decider = await embedder.createDecider(
      options: _options(),
      calibration: calibration,
      embedderId: 'fake',
    );
    expect(
      embedder.calls
          .map((c) => c.$1)
          .where((t) => const {'about a', 'about b', 'a or b'}.contains(t)),
      ['about a', 'about b', 'a or b'],
      reason: 'every row given at construction is embedded',
    );
    expect(decider.capabilities.calibratedProbabilities, isTrue);
    expect(calibration.toString(), contains('3 rows'));
  });

  test(
    'a held-out row that repeats an option description is refused',
    () async {
      final embedder = FakeEmbedder(dimension: 3, table: _table);
      await expectLater(
        embedder.createDecider(
          options: _options(),
          calibration: DeciderCalibration.fromLabelled([
            (input: _t('option a'), optionId: 'a'),
            (input: _t('about b'), optionId: 'b'),
          ]),
          embedderId: 'fake',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('repeats an option'),
          ),
        ),
      );
      expect(embedder.calls, isEmpty, reason: 'refused before embedding');
    },
  );
}
