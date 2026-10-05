// The WordPiece `tokenizer.json` parse step, split out of the web router so it
// carries no `dart:js_interop`: the router's fetch half cannot be loaded on the
// VM, and this half is the part worth unit-testing.

import 'dart:convert';

import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart'
    show EmbeddingTokenizer;

import 'wordpiece_embedding_tokenizer.dart' show WordPieceEmbeddingTokenizer;

/// The parse step on its own — no network, so it is unit-testable.
EmbeddingTokenizer parseWordPieceTokenizerJson(String text) {
  final json = jsonDecode(text) as Map<String, dynamic>;
  if (!WordPieceEmbeddingTokenizer.isWordPieceJson(json)) {
    throw UnsupportedError(
      'Web embedding backends that tokenize in Dart support WordPiece '
      '`tokenizer.json` exports only (all-MiniLM-L6-v2 and other BERT-family '
      'models) — got model.type='
      '"${(json['model'] as Map?)?['type']}". SentencePiece needs a pure-Dart '
      'parser that does not exist yet: dart_sentencepiece_tokenizer imports '
      'dart:io/dart:isolate unconditionally and cannot run on web. Native '
      'platforms are unaffected, and so is flutter_gemma_litertlm on web — it '
      'tokenizes in sentencepiece.js rather than in Dart.',
    );
  }
  return WordPieceEmbeddingTokenizer.fromJsonString(text);
}
