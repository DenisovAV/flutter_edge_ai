import 'package:flutter_gemma_speech/src/tokenizer/gpt2_byte_level_bpe_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Gpt2ByteLevelBpeTokenizer tokenizerWith(
    Map<String, int> vocab, {
    required int eosId,
  }) => Gpt2ByteLevelBpeTokenizer.fromJson({
    'model': {'type': 'BPE', 'vocab': vocab},
  }, eosId: eosId);

  test('decodes plain ASCII tokens (self-mapped GPT-2 byte range)', () {
    // Bytes 0x21-0x7E ('!'..'~') self-map in the GPT-2 byte-to-unicode
    // table, so an ASCII word is its own vocab piece.
    final t = tokenizerWith({'Hello': 0}, eosId: 999);
    expect(t.decode([0]), 'Hello');
  });

  test(
    'Ġ (U+0120) decodes to a leading space (GPT-2 word-boundary byte 0x20)',
    () {
      final t = tokenizerWith({'Ġworld': 0}, eosId: 999);
      expect(t.decode([0]), ' world');
    },
  );

  test('reassembles a multibyte UTF-8 char split across two token ids', () {
    // 'é' = UTF-8 bytes [0xC3, 0xA9]. Both bytes fall in the GPT-2
    // self-mapped Latin-1 ranges (0xA1-0xAC, 0xAE-0xFF), so byte 0xC3 ->
    // 'Ã' (U+00C3) and byte 0xA9 -> '©' (U+00A9) -- the classic "GPT-2
    // mangles raw UTF-8 into latin1-looking noise" artifact. Splitting
    // across two separate vocab entries proves decode reassembles bytes
    // across MULTIPLE token ids before the final UTF-8 decode, not
    // per-token (a per-token decode would produce mojibake/invalid UTF-8).
    final t = tokenizerWith({'Ã': 0, '©': 1}, eosId: 999);
    expect(t.decode([0, 1]), 'é');
  });

  test('stops at eosId, ignoring anything after', () {
    final t = tokenizerWith({'Hi': 0, 'Ġthere': 1}, eosId: 5);
    expect(t.decode([0, 1, 5, 7]), 'Hi there');
  });

  test(
    'skips ids >= base vocab size (added/special tokens) when reached before eos',
    () {
      final t = tokenizerWith({'Hi': 0}, eosId: 999);
      expect(t.decode([0, 1]), 'Hi'); // id 1 >= baseVocabSize(1) -> skipped
    },
  );
}
