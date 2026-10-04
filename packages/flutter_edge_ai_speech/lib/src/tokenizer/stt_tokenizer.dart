// Whisper's decode is GPT-2 byte-level BPE; moonshine's is SentencePiece.
// Different ALGORITHMS, not different parameters -- so this is an
// interface with per-family implementations (SentencePieceTokenizer,
// Gpt2ByteLevelBpeTokenizer), selected once at SttCore.load() time by
// SttModelProfile.tokenizerKind, not branched on in the hot decode loop.
library;

import 'gpt2_byte_level_bpe_tokenizer.dart';
import 'parakeet_bpe_tokenizer.dart';
import 'sentence_piece_tokenizer.dart';

/// Which decode-tokenizer family a profile uses. Lives here (not in
/// stt_model_profile.dart) so the profile can reference it without this
/// file depending back on the profile -- Phase 3 imports this enum.
enum SttTokenizerKind { sentencePiece, gpt2ByteLevelBpe, parakeetBpe }

abstract interface class SttTokenizer {
  /// Turn a generated id sequence into text. Implementations stop at their
  /// family's EOS id and skip special/added-vocab ids.
  String decode(List<int> ids);

  /// Build the tokenizer [kind] selects from the parsed `tokenizer.json`
  /// document [tokenizerJson]. [eosId] is the ALREADY-RESOLVED EOS id
  /// (resolved once by the caller via `SttSpecialTokenResolver`, so every
  /// family's decode loop and detokenizer agree on the same id).
  ///
  /// [eosId] is required for `gpt2ByteLevelBpe` (whisper always resolves
  /// one) and unused/optional for `sentencePiece`/`parakeetBpe` (moonshine
  /// resolves its own fixed EOS internally; parakeet's CTC decode has no
  /// EOS concept at all).
  static SttTokenizer forProfileKind(
    SttTokenizerKind kind,
    Map<String, dynamic> tokenizerJson, {
    int? eosId,
  }) => switch (kind) {
    SttTokenizerKind.sentencePiece => SentencePieceTokenizer.fromJson(
      tokenizerJson,
    ),
    SttTokenizerKind.gpt2ByteLevelBpe => Gpt2ByteLevelBpeTokenizer.fromJson(
      tokenizerJson,
      eosId: eosId!,
    ),
    SttTokenizerKind.parakeetBpe => ParakeetBpeTokenizer.fromJson(
      tokenizerJson,
    ),
  };
}
