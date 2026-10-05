/// Minimal HuggingFace `tokenizer.json` reader — DETOKENIZE ONLY — implements [SttTokenizer].
///
/// Encode is not needed for STT output (the model produces token ids
/// directly). This implements exactly the verified scheme recorded in
/// `docs/superpowers/notes/stt-transcript-recipe.md` ("Detokenize (verified
/// against `moonshine_tokenizer.json`)"): a BPE vocab (`model.vocab`,
/// piece→id) plus a fixed decode pipeline —
/// `▁` → space, `<0xHH>` → raw byte (ByteFallback), fuse into one UTF-8
/// buffer, strip exactly one leading space — stopping at `</s>` and
/// skipping `<unk>`/`<s>`/added-vocab ids.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'stt_tokenizer.dart';

/// Matches LLaMA-style BPE byte-fallback pieces, e.g. `<0x0A>`.
final RegExp _byteFallbackPattern = RegExp(r'^<0x([0-9A-Fa-f]{2})>$');

/// SentencePiece's "start of word" marker (U+2581), replaced with a literal
/// space during detokenize.
const String _wordBoundary = '▁';

class SentencePieceTokenizer implements SttTokenizer {
  SentencePieceTokenizer._({
    required this._idToPiece,
    required this.unkId,
    required this.bosId,
    required this.eosId,
    required this.baseVocabSize,
  });

  final Map<int, String> _idToPiece;

  /// `<unk>` id — skipped when detokenizing.
  final int unkId;

  /// `<s>` id — the decode loop's start token; skipped when detokenizing.
  final int bosId;

  /// `</s>` id — stops detokenization.
  final int eosId;

  /// Ids `>= baseVocabSize` are added/special tokens (e.g. moonshine's
  /// `<<ST_n>>`) and are skipped when detokenizing.
  final int baseVocabSize;

  /// Load a `tokenizer.json` file from disk.
  static Future<SentencePieceTokenizer> fromFile(String path) async {
    final text = await File(path).readAsString();
    return SentencePieceTokenizer.fromJson(
      jsonDecode(text) as Map<String, dynamic>,
    );
  }

  /// Parse a `tokenizer.json` document. Pure (no I/O) — used directly by
  /// tests against a canned document.
  factory SentencePieceTokenizer.fromJson(Map<String, dynamic> doc) {
    final model = doc['model'] as Map<String, dynamic>;
    final vocab = model['vocab'] as Map<String, dynamic>;
    final pieceToId = <String, int>{
      for (final entry in vocab.entries) entry.key: entry.value as int,
    };
    final idToPiece = <int, String>{
      for (final entry in pieceToId.entries) entry.value: entry.key,
    };

    return SentencePieceTokenizer._(
      idToPiece: idToPiece,
      unkId: pieceToId['<unk>'] ?? 0,
      bosId: pieceToId['<s>'] ?? 1,
      eosId: pieceToId['</s>'] ?? 2,
      baseVocabSize: idToPiece.length,
    );
  }

  /// Turn a generated id sequence into text, per the verified recipe:
  /// 1. stop at [eosId]; skip [unkId], [bosId], and any id `>= baseVocabSize`.
  /// 2. for each remaining id's piece: a `<0xHH>` piece pushes the raw byte
  ///    (ByteFallback); otherwise `▁` → space, UTF-8-encode, and push those
  ///    bytes (Replace + Fuse).
  /// 3. UTF-8-decode the accumulated bytes (`allowMalformed: true`).
  /// 4. strip exactly one leading space, if present (Strip start=1).
  @override
  String decode(List<int> ids) {
    final bytes = BytesBuilder();
    for (final id in ids) {
      if (id == eosId) break;
      if (id == unkId || id == bosId || id >= baseVocabSize) continue;
      final piece = _idToPiece[id];
      // An id in [0, baseVocabSize) with no vocab piece is dropped rather than
      // thrown on: detokenization must stay robust to a stray/garbled id from
      // the model (a decode-time output artifact, not a config error) — unlike
      // the FAIL-LOUD special-token *resolution* in stt_special_tokens.dart,
      // which throws on a MISSING configured token because that IS a config
      // error. A dense HF vocab has no such gaps in practice.
      if (piece == null) continue;

      final byteFallback = _byteFallbackPattern.firstMatch(piece);
      if (byteFallback != null) {
        bytes.addByte(int.parse(byteFallback.group(1)!, radix: 16));
      } else {
        bytes.add(utf8.encode(piece.replaceAll(_wordBoundary, ' ')));
      }
    }

    var text = utf8.decode(bytes.toBytes(), allowMalformed: true);
    if (text.startsWith(' ')) {
      text = text.substring(1);
    }
    return text;
  }
}
