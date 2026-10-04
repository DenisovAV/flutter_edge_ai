// Parakeet's tokenizer: an HF `tokenizers`-library BPE CONTAINER around a
// SentencePiece-trained vocab (`nvidia/parakeet-ctc-0.6b/tokenizer.json`).
// DECODE ONLY, and deliberately NOT `SentencePieceTokenizer`: CTC has no
// BOS/EOS, and `SentencePieceTokenizer`'s `bosId`/`eosId` DEFAULT to 1/2
// when `<s>`/`</s>` are absent from the vocab (this vocab has neither) --
// reusing it verbatim would wrongly strip real subword ids 1 (`▁t`) and 2
// (`▁th`). Per the verified recipe
// (docs/superpowers/notes/parakeet-ctc-spike-findings.md "Tokenizer
// format"): piece lookup, `▁` -> space, join, trim -- no bos/eos concept
// at all. The blank id (1024, NOT in `model.vocab`) and `<pad>` are simply
// absent from the id->piece map and are therefore skipped defensively --
// though in practice `ctcGreedyDecode` has already dropped the blank id
// before this ever sees it.
library;

import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'stt_tokenizer.dart';

const String _wordBoundary = '▁';

class ParakeetBpeTokenizer implements SttTokenizer {
  ParakeetBpeTokenizer._(this._idToPiece);

  final Map<int, String> _idToPiece;

  /// Parse a `tokenizer.json` document. Pure (no I/O).
  factory ParakeetBpeTokenizer.fromJson(Map<String, dynamic> doc) {
    final model = doc['model'] as Map<String, dynamic>;
    final vocab = model['vocab'] as Map<String, dynamic>;
    final idToPiece = <int, String>{
      for (final entry in vocab.entries) entry.value as int: entry.key,
    };
    return ParakeetBpeTokenizer._(idToPiece);
  }

  /// Turn a (already CTC-collapsed, blank-dropped) id sequence into text:
  /// look up each id's piece (skip ids not in the vocab), `▁` -> space,
  /// concatenate, trim. NO bos/eos handling -- CTC has none.
  @override
  String decode(List<int> ids) {
    final bytes = BytesBuilder();
    for (final id in ids) {
      final piece = _idToPiece[id];
      if (piece == null) continue;
      bytes.add(utf8.encode(piece.replaceAll(_wordBoundary, ' ')));
    }
    return utf8.decode(bytes.toBytes(), allowMalformed: true).trim();
  }
}
