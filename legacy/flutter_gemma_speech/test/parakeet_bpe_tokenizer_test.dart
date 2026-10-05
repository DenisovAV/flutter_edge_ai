import 'package:flutter_gemma_speech/src/tokenizer/parakeet_bpe_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ParakeetBpeTokenizer tokenizerWith(Map<String, int> vocab) =>
      ParakeetBpeTokenizer.fromJson({
        'model': {'type': 'BPE', 'vocab': vocab},
      });

  test(
    'decodes pieces, replacing (U+2581) with space, joining and trimming',
    () {
      final tokenizer = tokenizerWith({'▁she': 10, '▁had': 11, '▁your': 12});
      expect(tokenizer.decode([10, 11, 12]), 'she had your');
    },
  );

  test('ids 1 and 2 are ordinary subwords here, NOT stripped as bos/eos '
      '(the bos/eos-collision guard SentencePieceTokenizer would trip)', () {
    final tokenizer = tokenizerWith({'▁t': 1, '▁th': 2, '▁e': 3});
    expect(tokenizer.decode([1, 2, 3]), 't th e');
  });

  test(
    'ids not present in the vocab (e.g. the blank id, <pad>) are skipped',
    () {
      final tokenizer = tokenizerWith({'▁hi': 5});
      expect(tokenizer.decode([5, 1024, 1025]), 'hi');
    },
  );

  test('an empty id list decodes to an empty string', () {
    final tokenizer = tokenizerWith({'▁hi': 5});
    expect(tokenizer.decode(const []), '');
  });
}
