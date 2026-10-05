// Pure-function tests for `pickOnnxOutputIndex` — zero dlopen, zero fakes
// (design D-T4's "zero dlopen" bar for host-verifiable unit tests).

import 'package:flutter_gemma_onnx/src/embedding/ort_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pickOnnxOutputIndex', () {
    test('prefers sentence_embedding over everything else', () {
      expect(
        pickOnnxOutputIndex(['last_hidden_state', 'sentence_embedding']),
        1,
      );
      expect(
        pickOnnxOutputIndex(['sentence_embedding', 'last_hidden_state']),
        0,
      );
      // sentence_embedding wins even when pooler_output is also present.
      expect(pickOnnxOutputIndex(['pooler_output', 'sentence_embedding']), 1);
    });

    test('prefers pooler_output over last_hidden_state', () {
      // pooler_output is a pre-pooled `[1, dim]` sentence embedding (SigLIP2 /
      // BERT-style), not per-token hidden states, so it must be picked over
      // last_hidden_state (which would otherwise be mean-pooled).
      expect(pickOnnxOutputIndex(['pooler_output', 'last_hidden_state']), 0);
      expect(pickOnnxOutputIndex(['last_hidden_state', 'pooler_output']), 1);
    });

    test(
      'falls back to last_hidden_state when no pre-pooled output is present',
      () {
        expect(pickOnnxOutputIndex(['last_hidden_state', 'logits']), 0);
        expect(pickOnnxOutputIndex(['logits', 'last_hidden_state']), 1);
      },
    );

    test(
      'falls back to the first output when neither canonical name is present',
      () {
        expect(pickOnnxOutputIndex(['logits']), 0);
        expect(pickOnnxOutputIndex(['logits', 'extra']), 0);
      },
    );

    test('single-output graphs return index 0 regardless of name', () {
      expect(pickOnnxOutputIndex(['last_hidden_state']), 0);
      expect(pickOnnxOutputIndex(['sentence_embedding']), 0);
    });
  });
}
