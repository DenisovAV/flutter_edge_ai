// Runtime-agnostic tokenization half of the embedding pipeline (embedder
// decoupling plan Task 3, Invariant I1).
//
// The Gemma BOS/EOS convention and the `.json`-vs-`.model` loader branch live
// here rather than inside a forward pass because they are engine-agnostic (pure
// Dart, `dart_sentencepiece_tokenizer` only). The length check and the padding
// to a graph's `seqLen` deliberately do NOT: core's `TokenEmbeddingPass` refuses
// an input longer than the graph takes, and the engine's pass pads, because only
// that engine's model knows its fixed `seqLen`.
//
// ⚠️ I1 risk: getting `bosId`/`eosId` or the `prefix + text` concatenation
// order wrong silently changes every embedding vector without any exception.
//
// The content ids are SentencePiece's, not the dependency's alone: the
// dependency splits Gemma's user-defined pieces (`</div>`, `<mask>`, …) that
// SentencePiece keeps whole, so the loader reads them from the file and
// [encodeForEmbedding] / [encodeForSiglipEmbedding] match them first
// (`user_defined_pieces.dart`; test/sentencepiece_reference_test.dart compares
// every row of a fixed corpus with the Python `sentencepiece` package).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';

import 'package:flutter_edge_ai/engine.dart';
import 'tokenizer_contract.dart';
import 'sentencepiece_model_proto.dart';
import 'user_defined_pieces.dart';

/// Gemma special-token IDs, added by this package rather than by the loader:
/// `loadEmbeddingTokenizer` passes an explicit `SentencePieceConfig` with
/// `addBosToken`/`addEosToken` false, and every loader version takes the
/// caller's config over the file's `post_processor`. So these are the only
/// terminators `encodeForEmbedding` produces, whatever the file declares.
const int bosId = 2;
const int eosId = 1;

/// Loads the SentencePiece tokenizer at [tokenizerPath] — a `.json` (via
/// `TokenizerJsonLoader`) or a raw SentencePiece `.model` file.
///
/// The returned tokenizer has any `padding` and `truncation` the file declares
/// DISABLED: `encode()` hands back bare content, never a fixed-width row. Width
/// and terminators are the caller's — [encodeForEmbedding],
/// [encodeForSiglipEmbedding], and the embedding pass that owns `seqLen`. (A raw
/// `.model` carries no such blocks, so there the guarantee is free.)
///
/// The returned tokenizer is the dependency's, loaded from the file as it
/// always was: its own `encode()` is unchanged. [encodeForEmbedding] and
/// [encodeForSiglipEmbedding] add what this function read from the file, and
/// tokenize as SentencePiece does: the model's user-defined pieces (Gemma's
/// `</div>`, `<mask>`, `<start_of_turn>`, …) matched first and kept whole, and
/// `<pad>`, `<eos>`, `<bos>` and `<unk>` never produced from text. For a
/// HuggingFace `tokenizer.json` in Gemma's shape the text between two pieces
/// needs a second tokenizer, loaded from the same file without its
/// `added_tokens`. It is built the first time one of those two functions runs
/// on the returned tokenizer, by reading [tokenizerPath] again: a
/// [StateError] then if the file is gone or has changed since. (The embedding
/// route — [loadGemmaSentencePieceEmbeddingTokenizer],
/// [loadSiglipSentencePieceEmbeddingTokenizer] — builds only that second
/// tokenizer and never the first.)
///
/// Throws [UnsupportedError] for a BPE model with user-defined pieces whose
/// normalizer this package cannot reproduce them under, and
/// [FormatException] for a `tokenizer.json` whose added tokens the file alone
/// cannot type (`user_defined_pieces.dart` says which) — both rather than
/// return ids that differ from SentencePiece's without a sign.
///
/// Throws [StateError] if the resolved `dart_sentencepiece_tokenizer` accepts
/// the calls that disable those settings and leaves them set anyway. That is a
/// check on the tokenizer's config, not a guarantee about `encode()`'s output.
Future<SentencePieceTokenizer> loadEmbeddingTokenizer(
  String tokenizerPath,
) async {
  // Why the disable lives here and not in each profile.
  //
  // On 1.4.1 a SigLIP 2 `tokenizer.json` (which declares `{Fixed: 64, Right}`)
  // comes back already padded: the loader applies the file's own blocks
  // regardless of the config passed here. Both `encodeForEmbedding` and
  // `encodeForSiglipEmbedding` append their own EOS after whatever they are
  // handed, which puts it past the pad run — every id in range, nothing thrown,
  // and a different vector, since SigLIP pools the LAST position.
  //
  // Undoing that afterwards was possible but was a heuristic over a pipeline
  // nobody checks: it assumed right-padding with id 0, and a file declaring
  // `"direction": "Left"` or another `pad_id` would have slipped through
  // silently. Turning the feature off is the same result without the assumption,
  // and it keeps this package owning its own width rule.
  //
  // `_applyTokenizerSettings` is HF-JSON-only, so on the `.model` arm the two
  // calls are a no-op today. They stay because the contract above is one
  // sentence for both arms, and it should not quietly depend on which ran.
  return _load(tokenizerPath, forEmbedding: false);
}

/// Loads [path] as [loadEmbeddingTokenizer] does, for the public API or — when
/// [forEmbedding] — for the embedding route, which needs only the tokenizer
/// that encodes content: for a HuggingFace `tokenizer.json` in Gemma's shape
/// that is the one without `added_tokens`, and the file's full tokenizer is
/// never built (it is a second ~0.6 s and ~70 MB on EmbeddingGemma's 20 MB
/// file).
Future<SentencePieceTokenizer> _load(
  String path, {
  required bool forEmbedding,
}) async {
  final (tokenizer, pass) = path.endsWith('.json')
      ? _loadJson(
          await File(path).readAsString(),
          path,
          forEmbedding: forEmbedding,
        )
      : _loadModel(await File(path).readAsBytes(), path);
  if (pass != null) _userDefinedPass[tokenizer] = pass;
  // The cascade is the mechanism; `requireBareContent` is the enforcement, and
  // it is separate because `^1.4.1` is open-topped. See its doc for exactly
  // which failure shapes it does and does not cover — the ones it cannot see
  // are `siglip_loader_contract_test.dart`'s job.
  return _bare(tokenizer, path);
}

/// [tokenizer] with the file's own padding and truncation switched off, and
/// checked to be off (see [loadEmbeddingTokenizer] for why).
SentencePieceTokenizer _bare(SentencePieceTokenizer tokenizer, String path) {
  tokenizer
    ..noPadding()
    ..noTruncation();
  return requireBareContent(tokenizer, path);
}

/// SentencePiece's user-defined pass for one loaded file: its pieces, and the
/// tokenizer that encodes the text between two of them — one that matches no
/// added token of its own. For a `.model`, the dependency's own JSON and the
/// embedding route that is the loaded tokenizer itself; for a HuggingFace
/// `tokenizer.json` loaded through [loadEmbeddingTokenizer], a second one,
/// built on first use.
final class _UserDefinedPass {
  _UserDefinedPass(this.pieces, SentencePieceTokenizer stretches)
    : _stretches = stretches,
      _build = null;

  _UserDefinedPass.lazy(this.pieces, SentencePieceTokenizer Function() build)
    : _build = build;

  final UserDefinedPieces pieces;
  final SentencePieceTokenizer Function()? _build;
  SentencePieceTokenizer? _stretches;

  SentencePieceTokenizer get stretches => _stretches ??= _build!();
}

/// What [loadEmbeddingTokenizer] read about each tokenizer it returned, when
/// the file has user-defined pieces SentencePiece's way can be reproduced for
/// (see `user_defined_pieces.dart`). Absent for any other tokenizer, which then
/// encodes exactly as the dependency does.
final _userDefinedPass = Expando<_UserDefinedPass>(
  'SentencePiece user-defined pass',
);

(SentencePieceTokenizer, _UserDefinedPass?) _loadModel(
  Uint8List bytes,
  String path,
) {
  final model = SentencePieceModelProto.parse(bytes);
  // Read first: a model this package refuses fails before the dependency
  // spends a load on it.
  final pieces = UserDefinedPieces.fromModelProto(model, source: path);
  // The dependency drops a leading U+FEFF from every piece it decodes, which
  // gives Gemma's `<?` and `//` the ids of `\ufeff<?` and `\ufeff//`. Hand it
  // a file it reads right, and check that it did.
  final tokenizer = SentencePieceTokenizer.fromBytes(
    model.bomLed.isNotEmpty && _dependencyDropsLeadingBom
        ? withLeadingBomsKept(bytes)
        : bytes,
    config: const SentencePieceConfig(),
  );
  for (final MapEntry(key: id, value: piece) in model.bomLed.entries) {
    final readAs = tokenizer.convertIdsToTokens([id]).single;
    final idOf = tokenizer.convertTokensToIds([piece]).single;
    if (readAs != piece || idOf != id) {
      throw StateError(
        'dart_sentencepiece_tokenizer read piece $id ${jsonEncode(piece)} as '
        '${jsonEncode(readAs)}, and gives that text id $idOf: its ids for '
        'text containing it would be wrong. Pin dart_sentencepiece_tokenizer '
        'to a version this package handles; 1.4.1 is known good.',
      );
    }
  }
  return (
    tokenizer,
    pieces == null ? null : _UserDefinedPass(pieces, tokenizer),
  );
}

/// Whether `dart_sentencepiece_tokenizer` drops ONE leading U+FEFF from a
/// piece it reads from a `.model` (1.4.1 does: it decodes with `utf8.decode`).
/// Asked of the dependency itself, once, with a one-piece model whose piece
/// is `\ufeff\ufeffx`; any answer but `\ufeffx` (dropped one) or
/// `\ufeff\ufeffx` (kept both) is a reader this package cannot correct.
final bool _dependencyDropsLeadingBom = () {
  const probe = '\ufeff\ufeffx';
  final readAs = SentencePieceTokenizer.fromBytes(
    // ModelProto { pieces { piece: probe } }
    Uint8List.fromList(const [
      0x0A, 9, // pieces, 9 bytes
      0x0A, 7, // piece, 7 bytes
      0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x78,
    ]),
  ).convertIdsToTokens([0]).single;
  if (readAs == probe) return false;
  if (readAs == probe.substring(1)) return true;
  throw StateError(
    'dart_sentencepiece_tokenizer reads the piece ${jsonEncode(probe)} as '
    '${jsonEncode(readAs)}; this package cannot correct that. Pin it to '
    '1.4.1.',
  );
}();

(SentencePieceTokenizer, _UserDefinedPass?) _loadJson(
  String raw,
  String path, {
  required bool forEmbedding,
}) {
  final json = jsonDecode(raw);
  if (json is! Map<String, dynamic>) {
    throw FormatException('$path is not a JSON object');
  }
  if (!TokenizerJsonLoader.isHuggingFaceFormat(json)) {
    // The package's own format: it registers no added tokens, so the pieces
    // read from its types are the only thing to add.
    final tokenizer = TokenizerJsonLoader.fromJsonString(
      raw,
      config: const SentencePieceConfig(),
    );
    final pieces = UserDefinedPieces.fromLibraryJson(json, source: path);
    return (
      tokenizer,
      pieces == null ? null : _UserDefinedPass(pieces, tokenizer),
    );
  }
  // Read first: a file this package refuses fails before the expensive load.
  final gemma = UserDefinedPieces.fromHuggingFaceJson(json, source: path);
  if (gemma == null) {
    return (
      HuggingFaceTokenizerLoader.fromMap(
        json,
        config: const SentencePieceConfig(),
      ),
      null,
    );
  }
  if (forEmbedding) {
    final stretches = HuggingFaceTokenizerLoader.fromMap(
      gemma.stretchJson,
      config: const SentencePieceConfig(),
    );
    return (stretches, _UserDefinedPass(gemma.pieces, stretches));
  }
  final tokenizer = HuggingFaceTokenizerLoader.fromMap(
    json,
    config: const SentencePieceConfig(),
  );
  final loadedAs = FileStat.statSync(path);
  return (
    tokenizer,
    _UserDefinedPass.lazy(gemma.pieces, () => _stretchesFor(path, loadedAs)),
  );
}

/// The added-token-free tokenizer of the `tokenizer.json` at [path], read
/// again; [loadedAs] is what the file was when [loadEmbeddingTokenizer] read
/// it. Throws [StateError] when the file is gone, has changed since, or no
/// longer reads as it did.
SentencePieceTokenizer _stretchesFor(String path, FileStat loadedAs) {
  Never fail(String why) => throw StateError(
    '$path $why since loadEmbeddingTokenizer read it, and '
    'encodeForEmbedding / encodeForSiglipEmbedding read it again for the '
    'text between user-defined pieces. Load it again.',
  );
  final now = FileStat.statSync(path);
  if (now.type == FileSystemEntityType.notFound) fail('is gone');
  if (now.size != loadedAs.size || now.modified != loadedAs.modified) {
    fail('has changed');
  }
  final json = jsonDecode(File(path).readAsStringSync());
  final gemma = json is Map<String, dynamic>
      ? UserDefinedPieces.fromHuggingFaceJson(json, source: path)
      : null;
  if (gemma == null) fail('no longer reads as it did');
  return _bare(
    HuggingFaceTokenizerLoader.fromMap(
      gemma.stretchJson,
      config: const SentencePieceConfig(),
    ),
    path,
  );
}

/// The content ids of [text]: SentencePiece's user-defined pass when
/// [loadEmbeddingTokenizer] read one for [tokenizer], else its own `encode()`.
List<int> _contentIds(SentencePieceTokenizer tokenizer, String text) {
  final pass = _userDefinedPass[tokenizer];
  return pass == null
      ? tokenizer.encode(text).ids
      : pass.pieces.encode(pass.stretches, text);
}

/// Tokenizes ([prefix] + [text]) with Gemma BOS/EOS:
/// `[bosId, ...ids(prefix + text), eosId]`, where the ids are what
/// SentencePiece produces for a [tokenizer] from [loadEmbeddingTokenizer]
/// (its user-defined pieces kept whole) and `tokenizer.encode(...).ids` for
/// any other.
///
/// Does NOT pad to a fixed sequence length, nor check one — that is the
/// embedding pass's job (it owns `seqLen`, e.g. LiteRT's compiled input tensor
/// width, and refuses a longer input).
List<int> encodeForEmbedding(
  SentencePieceTokenizer tokenizer,
  String prefix,
  String text,
) => <int>[bosId, ..._contentIds(tokenizer, prefix + text), eosId];

/// [EmbeddingTokenizerFactory] tear-off (design D-T1) — a thin
/// [EmbeddingTokenizer] adapter over the loader and [encodeForEmbedding]: the
/// same ids [loadEmbeddingTokenizer] + [encodeForEmbedding] give, but for a
/// `tokenizer.json` only the tokenizer the embedding needs is built (see
/// [loadEmbeddingTokenizer]). Same BOS=2/EOS=1 convention, same
/// `prefix + text` concatenation order as the pre-generalization LiteRT
/// path. Always returns `attentionMask: null, tokenTypeIds: null` — Gemma
/// SentencePiece has no notion of either; the embedding pass pads internally
/// and has no mask to report back.
Future<EmbeddingTokenizer> loadGemmaSentencePieceEmbeddingTokenizer(
  String tokenizerPath,
) async {
  final tokenizer = await _load(tokenizerPath, forEmbedding: true);
  return _GemmaSentencePieceEmbeddingTokenizer(tokenizer);
}

class _GemmaSentencePieceEmbeddingTokenizer implements EmbeddingTokenizer {
  _GemmaSentencePieceEmbeddingTokenizer(this._tokenizer);

  final SentencePieceTokenizer _tokenizer;

  @override
  TokenizedInput encode(String prefix, String text) =>
      TokenizedInput(ids: encodeForEmbedding(_tokenizer, prefix, text));
}

// ─────────────────────────── SigLIP2 profile ───────────────────────────
//
// SigLIP2's text tower uses a DIFFERENT special-token convention from Gemma:
// NO leading BOS, a SINGLE trailing EOS (id 1), and its canonical preprocessing
// lowercases the text. The model's ONNX graph has a FIXED `input_ids [1, 64]`
// input, so the ids must carry the width. The SigLIP int8 export reads as
// DYNAMIC-shape, so the forward pass's `staticSeqLen` path does NOT pad it —
// [encodeForSiglipEmbedding] pads here instead. This is a SEPARATE adapter from
// the Gemma one (which hardcodes
// BOS=2/EOS=1) — routing the SigLIP profile here instead of to the Gemma adapter
// is what avoids the silent BOS-injection corruption; the Gemma path is
// untouched (non-regressing).

/// SigLIP2's trailing end-of-sequence id. No BOS is prepended.
const int siglipEosId = 1;

/// SigLIP2's fixed context width and pad id, both taken from the model's own
/// `tokenizer.json`, which bakes them in:
///
/// ```json
/// "padding": {"strategy": {"Fixed": 64}, "direction": "Right",
///             "pad_id": 0, "pad_token": "<pad>"}
/// ```
///
/// The width has to live in the ids. The int8 export reads as DYNAMIC-shape
/// (`OrtIoSpec.staticSeqLen == null`), so the forward pass never pads, and the
/// graph carries NO `attention_mask`. Worse, the head does not pool over the
/// sequence at all — `Siglip2TextModel` takes `last_hidden_state[:, -1, :]`
/// ("the last token's hidden state, which may be padding", upstream's own
/// comment). With right-padding the pooled vector therefore IS the pad
/// position, which is why the pad id is first-order: measured against a correct
/// vector, padding with 1 instead of 0 gives cosine 0.81-0.90 and reorders
/// retrieval; not padding at all gives 0.58-0.69.
///
/// SigLIP **2** only. SigLIP 1 is a different tokenizer entirely (T5 Unigram,
/// 32k vocab, pad = `</s>` = 1); SigLIP 2 uses the Gemma BPE tokenizer (256k,
/// `<pad>` = 0, `<eos>` = 1). Pointing this profile at a SigLIP 1 file
/// silently produces wrong vectors.
const int siglipSeqLen = 64;

/// The id every position past the content is filled with — `<pad>`, id 0 in the
/// SigLIP 2 vocabulary. See [siglipSeqLen] for why this one is not cosmetic:
/// with right-padding it is the position the head actually pools.
const int siglipPadId = 0;

/// Tokenizes [text] with SigLIP2's convention and returns exactly [siglipSeqLen]
/// ids: no BOS, the lowercased content, one trailing [siglipEosId], then
/// right-padding with [siglipPadId].
///
/// Content longer than `siglipSeqLen - 1` (63 tokens) throws
/// [EmbeddingInputTooLongException] with `maxInputTokens: 64` and
/// `actualTokens` = content + EOS. It used to be cut to its first 63 tokens —
/// a vector of a different text, with no error.
///
/// Takes the content text ALONE. The adapter deliberately does not hand a
/// TaskType prefix through — see [loadSiglipSentencePieceEmbeddingTokenizer].
List<int> encodeForSiglipEmbedding(
  SentencePieceTokenizer tokenizer,
  String text,
) {
  // `loadEmbeddingTokenizer` turns the tokenizer's own padding and truncation
  // off, so this is bare content and the width rule below is the only one that
  // applies. Without that the file's `{Fixed: 64}` block comes back applied and
  // the EOS appended here would land past the pad run.
  final content = _contentIds(tokenizer, text.toLowerCase());
  // Prefix-free, so the EOS is the only id beside the content.
  final actualTokens = content.length + 1;
  if (actualTokens > siglipSeqLen) {
    throw EmbeddingInputTooLongException(
      'The input is $actualTokens tokens (EOS included); the SigLIP 2 text '
      'tower takes at most $siglipSeqLen. Split the text and embed the '
      'pieces.',
      maxInputTokens: siglipSeqLen,
      actualTokens: actualTokens,
    );
  }
  final ids = <int>[...content, siglipEosId];
  return [...ids, ...List<int>.filled(siglipSeqLen - ids.length, siglipPadId)];
}

/// [EmbeddingTokenizerFactory] tear-off for the SigLIP2 text tower — the same
/// loader (`.json`/`.model` branch, embedding route) as Gemma's factory, but
/// wrapped with SigLIP's no-BOS/single-EOS/lowercase convention instead.
///
/// The returned tokenizer **ignores the TaskType prefix**. `TaskType` is an
/// EmbeddingGemma convention (`'task: search result | query: '`), and SigLIP's
/// text tower has no vocabulary for it: a prefix would be embedded as literal
/// leading text and move the vector off the space it shares with the vision
/// tower, which encodes an image with no prefix at all. Dropping it is not a
/// silent liberty — every `EmbeddingModel.embed` names a task, and only
/// `TaskType.none` has an empty prefix, so rejecting a non-empty one would make
/// this profile reachable only through `none`, and honoring one would make
/// `retrievalQuery` and `retrievalDocument` of the same string two different
/// points.
Future<EmbeddingTokenizer> loadSiglipSentencePieceEmbeddingTokenizer(
  String tokenizerPath,
) async {
  final tokenizer = await _load(tokenizerPath, forEmbedding: true);
  _assertSiglip2Vocab(tokenizer, tokenizerPath);
  return _SiglipSentencePieceEmbeddingTokenizer(tokenizer);
}

/// Fails loudly when [tokenizer] is not the SigLIP **2** (Gemma BPE) vocabulary.
///
/// Everything this profile hardcodes — [siglipPadId] 0, [siglipEosId] 1, no BOS
/// — is SigLIP 2's convention. SigLIP 1 ships a different tokenizer entirely
/// (T5 Unigram, 32k, pad = `</s>` = 1), and running it through here produces a
/// plausible vector that is simply wrong: the ids stay in range, nothing
/// throws, and the error only shows up as degraded retrieval. Since the model
/// pools the LAST position (see [siglipSeqLen]), a wrong pad id is the single
/// biggest way to get that silently.
void _assertSiglip2Vocab(SentencePieceTokenizer tokenizer, String path) {
  final pieces = tokenizer.convertIdsToTokens([siglipPadId, siglipEosId]);
  if (pieces[0] == '<pad>' && pieces[1] == '<eos>') return;
  throw ArgumentError.value(
    path,
    'tokenizerPath',
    'not a SigLIP 2 tokenizer: expected id $siglipPadId = <pad> and '
        'id $siglipEosId = <eos> (the Gemma BPE vocabulary SigLIP 2 uses), '
        'got ${pieces[0]} and ${pieces[1]}. SigLIP 1 uses a T5 Unigram vocab '
        'where id 1 is </s> and is NOT interchangeable — its embeddings would '
        'come out wrong rather than fail.',
  );
}

class _SiglipSentencePieceEmbeddingTokenizer implements EmbeddingTokenizer {
  _SiglipSentencePieceEmbeddingTokenizer(this._tokenizer);

  final SentencePieceTokenizer _tokenizer;

  @override
  TokenizedInput encode(String prefix, String text) {
    // [prefix] is deliberately dropped — see the factory's doc for why a
    // TaskType prefix is meaningless here and why throwing is not an option.
    final ids = encodeForSiglipEmbedding(_tokenizer, text);
    // This adapter BUILT the padding, so it is the only thing that knows which
    // positions are real. Reporting the mask matters even though the head pools
    // the last position rather than averaging: when the graph declares an
    // `attention_mask` input, the embedding pass otherwise fabricates an all-ones
    // one over the pad tail, and a graph that falls through to
    // `last_hidden_state` would mean-pool 63 pads into the vector.
    // Counted from the END rather than by locating the EOS. A tokenizer.json
    // that is not in Gemma's shape keeps the dependency's `added_tokens`
    // matching (1.4.x), so text containing a literal `<eos>` can carry id 1
    // mid-sequence and `indexOf(siglipEosId)` would stop there. The tail cannot
    // lie — everything past the EOS is padding this function just wrote, and
    // the EOS itself is never [siglipPadId].
    var realTokens = siglipSeqLen;
    while (realTokens > 0 && ids[realTokens - 1] == siglipPadId) {
      realTokens--;
    }
    return TokenizedInput(
      ids: ids,
      attentionMask: [
        ...List<int>.filled(realTokens, 1),
        ...List<int>.filled(siglipSeqLen - realTokens, 0),
      ],
    );
  }
}
