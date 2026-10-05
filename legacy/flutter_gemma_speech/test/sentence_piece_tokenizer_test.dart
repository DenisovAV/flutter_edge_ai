import 'package:flutter_gemma_speech/src/tokenizer/sentence_piece_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SentencePieceTokenizer tokenizerWith(Map<String, int> vocab) =>
      SentencePieceTokenizer.fromJson({
        'model': {'type': 'BPE', 'vocab': vocab},
      });

  test('skips BOS, stops at EOS, decodes word pieces', () {
    final tokenizer = tokenizerWith({
      '<unk>': 0,
      '<s>': 1,
      '</s>': 2,
      '▁Hello': 3,
      '▁world': 4,
    });
    final text = tokenizer.decode([1, 3, 4, 2, 999]);
    expect(text, 'Hello world');
  });

  test('byte-fallback pieces decode to raw bytes (no leading space)', () {
    final tokenizer = tokenizerWith({
      '<unk>': 0,
      '<s>': 1,
      '</s>': 2,
      '▁Hello': 3,
      '<0x21>': 4, // '!'
      '▁world': 5,
    });
    final text = tokenizer.decode([1, 3, 4, 5, 2]);
    expect(text, 'Hello! world');
  });

  test('multi-byte UTF-8 char split across byte-fallback pieces is reassembled '
      'across the fused buffer', () {
    // The real byte-fallback path: a single non-ASCII char is emitted as
    // SEVERAL <0xHH> pieces that only become valid UTF-8 once fused into one
    // buffer and decoded together (not per-piece). 'é' = U+00E9 = C3 A9 (2
    // bytes); '😀' = U+1F600 = F0 9F 98 80 (4 bytes). A per-piece decode would
    // produce replacement chars; correct reassembly yields the real glyphs.
    final tokenizer = tokenizerWith({
      '<unk>': 0,
      '<s>': 1,
      '</s>': 2,
      '▁caf': 3,
      '<0xC3>': 4,
      '<0xA9>': 5,
      '▁': 6,
      '<0xF0>': 7,
      '<0x9F>': 8,
      '<0x98>': 9,
      '<0x80>': 10,
    });
    final text = tokenizer.decode([1, 3, 4, 5, 6, 7, 8, 9, 10, 2]);
    expect(text, 'café 😀');
  });

  test('unk and added-vocab ids (>= base vocab size) are skipped', () {
    final tokenizer = tokenizerWith({
      '<unk>': 0,
      '<s>': 1,
      '</s>': 2,
      '▁Hi': 3,
    });
    final text = tokenizer.decode([1, 0, 3, 99, 2]);
    expect(text, 'Hi');
  });
}
