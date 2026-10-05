// Tokenizer routing, shared by every embedding backend.
//
// Nothing here is engine-specific and nothing ever was: it reads the
// tokenizer file and picks a family. Which family a model needs is a property
// of the MODEL — EmbeddingGemma is SentencePiece whether LiteRT or ONNX
// Runtime executes its weights, MiniLM is WordPiece either way. It lived in
// flutter_gemma_onnx until the tokenizer became a registered provider; LiteRT
// meanwhile hardcoded SentencePiece and would mis-tokenize anything else.
//
// One factory covers both model families — MiniLM
// (WordPiece `tokenizer.json`) and EmbeddingGemma-300M-ONNX (SentencePiece,
// either a raw binary `tokenizer.model`/`sentencepiece.model` OR a
// HuggingFace `tokenizer.json` whose `model.type` is `BPE`/`Unigram`, NOT
// `WordPiece`) — with no per-model config: it sniffs [tokenizerPath] (inside
// the worker isolate, per the sendability rule on
// `EmbeddingTokenizerFactory`) and routes to whichever adapter matches
// (design D-T1).
//
// The sniff MUST tolerate a non-JSON file: `onnx-community/
// embeddinggemma-300m-ONNX` ships BOTH a `tokenizer.json` (HF format, BPE)
// AND a raw-binary SentencePiece `tokenizer.model` — either is a valid
// install choice, and the raw `.model` is NOT valid UTF-8/JSON at all
// (`jsonDecode`/`readAsString` throws on it) — verified against the real
// downloaded file. WordPiece detection is therefore attempted, and any
// failure to parse as JSON falls through to the SentencePiece adapter
// (which itself branches on `.json` vs raw `.model`, matching the LiteRT
// path's `loadEmbeddingTokenizer`).

import 'dart:convert';
import 'dart:io';

import 'embedding_tokenizer.dart' show loadGemmaSentencePieceEmbeddingTokenizer;
import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart' show EmbeddingTokenizer;
import 'tokenizer_convention.dart' show isSiglip2TokenizerJson;
import 'wordpiece_embedding_tokenizer.dart' show WordPieceEmbeddingTokenizer;

/// [EmbeddingTokenizerFactory] tear-off — the production path for every
/// backend that tokenizes in Dart, LiteRT and ONNX alike. Routes:
///  - [tokenizerPath] parses as JSON AND `WordPieceEmbeddingTokenizer.isWordPieceJson`
///    matches -> WordPiece (MiniLM and BERT-family models).
///  - otherwise (not JSON at all — a raw SentencePiece `.model` binary — or
///    JSON but not a WordPiece model, e.g. HF `tokenizer.json` with
///    `model.type: BPE`) -> the Gemma SentencePiece adapter, same convention
///    as the LiteRT path (see `embedding_tokenizer.dart`'s byte-identity
///    guard).
Future<EmbeddingTokenizer> resolveEmbeddingTokenizer(
  String tokenizerPath,
) async {
  // Only attempt to read+decode as JSON for a `.json`-named file — a raw
  // SentencePiece `.model` binary is not valid UTF-8 at all, and
  // `File.readAsString` throws `FileSystemException` (not `FormatException`)
  // on invalid UTF-8, so gating on the extension avoids exception-driven
  // control flow for the common case (verified against a real
  // `tokenizer.model` download).
  if (tokenizerPath.endsWith('.json')) {
    try {
      final raw = await File(tokenizerPath).readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (WordPieceEmbeddingTokenizer.isWordPieceJson(json)) {
        return WordPieceEmbeddingTokenizer.fromJsonString(raw);
      }
      // Refuse rather than mis-tokenize. A SigLIP 2 tokenizer.json is BPE, so
      // without this it would fall through to the Gemma adapter below and get a
      // BOS injected, no lowercasing and no padding to 64 — every id in range,
      // nothing thrown, and a vector that is quietly the wrong point in the
      // embedding space. There is no third branch to route it to yet: selecting
      // a profile needs a signal this function is not given (SigLIP 2 and Gemma
      // share a vocabulary AND a tokenizer file format; only these pipeline
      // blocks differ). Until that selector exists, a loud failure is the
      // honest outcome.
      if (isSiglip2TokenizerJson(json)) {
        throw UnsupportedError(
          'This tokenizer.json declares the SigLIP 2 convention (fixed-width '
          'padding, an EOS-only post-processor and no BOS), which this '
          'router cannot select yet — it would be tokenized with '
          "Gemma's convention and produce wrong vectors silently. Register a "
          'higher-priority EmbeddingTokenizerProvider whose factory calls '
          'loadSiglipSentencePieceEmbeddingTokenizer from '
          'flutter_gemma_embeddings. Path: $tokenizerPath',
        );
      }
    } on FormatException {
      // A `.json`-named file that isn't actually valid JSON — fall through
      // to the SentencePiece adapter's own `.json`-vs-raw branch, which
      // will surface a clearer error if it's not SentencePiece either.
    }
  }
  // Everything that is not WordPiece and not SigLIP 2 lands here: a raw
  // SentencePiece `.model`, or a BPE tokenizer.json with Gemma's own
  // convention. See flutter_gemma_embeddings' README, "the SigLIP2 profile is
  // not selected automatically", for what a real selector would need.
  return loadGemmaSentencePieceEmbeddingTokenizer(tokenizerPath);
}
