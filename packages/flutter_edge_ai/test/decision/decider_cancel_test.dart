// createDecider's cancelToken: a cancel fails the call with
// EmbeddingCancelledException wherever it lands, and never returns a decider.

import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_embedder.dart';

final _table = <String, List<double>>{
  'a1': [1, 0, 0],
  'a2': [0.9, 0.1, 0],
  'b1': [0, 1, 0],
  'b2': [0.1, 0.9, 0],
};

EmbeddingInput _t(String text) => EmbeddingInput.text(text);

List<DeciderOption> _options() => [
  DeciderOption('a', examples: [_t('a1'), _t('a2')]),
  DeciderOption('b', examples: [_t('b1'), _t('b2')]),
];

void main() {
  test(
    'a cancel while requests are outstanding fails the call at once',
    () async {
      final embedder = FakeEmbedder(dimension: 3, table: _table)
        ..hold = Completer<void>();
      final token = CancelToken();
      final created = embedder.createDecider(
        options: _options(),
        embedderId: 'fake',
        cancelToken: token,
      );
      await pumpEventQueue();
      expect(embedder.calls, hasLength(2), reason: 'two requests outstanding');
      token.cancel();
      await expectLater(
        created.timeout(const Duration(seconds: 5)),
        throwsA(isA<EmbeddingCancelledException>()),
      );
      embedder.hold!.complete();
      await pumpEventQueue();
      expect(embedder.calls, hasLength(2), reason: 'nothing sent after cancel');
    },
  );
}
