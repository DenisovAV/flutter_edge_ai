import 'package:flutter_gemma_speech/src/tokenizer/gpt2_byte_level_bpe_tokenizer.dart';
import 'package:flutter_gemma_speech/src/tokenizer/parakeet_bpe_tokenizer.dart';
import 'package:flutter_gemma_speech/src/tokenizer/sentence_piece_tokenizer.dart';
import 'package:flutter_gemma_speech/src/tokenizer/stt_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('forProfileKind(sentencePiece) builds a SentencePieceTokenizer', () {
    final t = SttTokenizer.forProfileKind(SttTokenizerKind.sentencePiece, {
      'model': {
        'type': 'BPE',
        'vocab': {'<unk>': 0, '<s>': 1, '</s>': 2, '▁hi': 3},
      },
    }, eosId: 2);
    expect(t, isA<SentencePieceTokenizer>());
    expect(t.decode([1, 3, 2]), 'hi');
  });

  test(
    'forProfileKind(gpt2ByteLevelBpe) builds a Gpt2ByteLevelBpeTokenizer with the given eosId',
    () {
      final t = SttTokenizer.forProfileKind(SttTokenizerKind.gpt2ByteLevelBpe, {
        'model': {
          'type': 'BPE',
          'vocab': {'Hi': 0},
        },
      }, eosId: 50);
      expect(t, isA<Gpt2ByteLevelBpeTokenizer>());
      expect(t.decode([0, 50, 999]), 'Hi');
    },
  );

  test(
    'forProfileKind(parakeetBpe) builds a ParakeetBpeTokenizer (no eosId needed)',
    () {
      final t = SttTokenizer.forProfileKind(SttTokenizerKind.parakeetBpe, {
        'model': {
          'type': 'BPE',
          'vocab': {'▁hi': 5},
        },
      });
      expect(t, isA<ParakeetBpeTokenizer>());
      expect(t.decode([5]), 'hi');
    },
  );
}
