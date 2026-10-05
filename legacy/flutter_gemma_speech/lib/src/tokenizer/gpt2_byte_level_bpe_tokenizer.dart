// Whisper's tokenizer: GPT-2 byte-level BPE. DECODE ONLY (the model
// produces token ids directly; encoding text isn't needed for STT output,
// same rationale as SentencePieceTokenizer). No BPE merge table is needed
// for decode -- `tokenizer.json`'s `model.vocab` already maps each
// complete BPE token STRING (itself byte-level-encoded, e.g. "Ġhello") to
// its id; decode just looks the string up and inverts the byte<->unicode
// mapping. Ports the reference `bytes_to_unicode()` from OpenAI's
// `gpt2/encoder.py` / HF's `tokenization_gpt2.py`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'stt_tokenizer.dart';

/// GPT-2's byte<->unicode mapping: every raw byte 0..255 maps to a
/// printable unicode code point, so arbitrary bytes round-trip through a
/// BPE vocab of "characters". Bytes in the printable ranges (`!`-`~`,
/// `¡`-`¬`, `®`-`ÿ`) map to themselves; the rest are assigned code points
/// starting at 256, in byte order.
Map<int, int> _gpt2ByteToUnicode() {
  final bytes = <int>[
    for (var b = 0x21; b <= 0x7E; b++) b,
    for (var b = 0xA1; b <= 0xAC; b++) b,
    for (var b = 0xAE; b <= 0xFF; b++) b,
  ];
  final selfMapped = bytes.toSet();
  final codepoints = <int>[...bytes];
  var n = 0;
  for (var b = 0; b < 256; b++) {
    if (!selfMapped.contains(b)) {
      bytes.add(b);
      codepoints.add(256 + n);
      n++;
    }
  }
  final map = <int, int>{};
  for (var i = 0; i < bytes.length; i++) {
    map[bytes[i]] = codepoints[i];
  }
  return map;
}

class Gpt2ByteLevelBpeTokenizer implements SttTokenizer {
  Gpt2ByteLevelBpeTokenizer._({
    required this._idToToken,
    required this.eosId,
    required this.baseVocabSize,
  }) : _unicodeToByte = {
         for (final e in _gpt2ByteToUnicode().entries) e.value: e.key,
       };

  final Map<int, String> _idToToken;
  final Map<int, int> _unicodeToByte;

  /// End-of-sequence id, already resolved by the caller (e.g. via
  /// `SttSpecialTokenResolver`) -- this class doesn't parse `added_tokens`
  /// itself, since decode only needs the base BPE vocab + the one EOS id.
  final int eosId;

  /// Ids `>= baseVocabSize` are added/special tokens (forced-prompt
  /// tokens, timestamps, ...) and are skipped when decoding.
  final int baseVocabSize;

  factory Gpt2ByteLevelBpeTokenizer.fromJson(
    Map<String, dynamic> doc, {
    required int eosId,
  }) {
    final model = doc['model'] as Map<String, dynamic>;
    final vocab = model['vocab'] as Map<String, dynamic>;
    final idToToken = <int, String>{
      for (final entry in vocab.entries) entry.value as int: entry.key,
    };
    return Gpt2ByteLevelBpeTokenizer._(
      idToToken: idToToken,
      eosId: eosId,
      baseVocabSize: vocab.length,
    );
  }

  @override
  String decode(List<int> ids) {
    final bytes = BytesBuilder();
    for (final id in ids) {
      if (id == eosId) break;
      if (id >= baseVocabSize) continue;
      final token = _idToToken[id];
      if (token == null) continue;
      for (final rune in token.runes) {
        final byte = _unicodeToByte[rune];
        if (byte != null) bytes.addByte(byte);
      }
    }
    return utf8.decode(bytes.toBytes(), allowMalformed: true);
  }
}
