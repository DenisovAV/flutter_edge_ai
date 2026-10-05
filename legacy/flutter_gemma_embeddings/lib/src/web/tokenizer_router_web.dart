// Tokenizer routing, web arm.
//
// Web can only do WordPiece in Dart: `dart_sentencepiece_tokenizer` imports
// `dart:io`/`dart:isolate` unconditionally and cannot be compiled for the web
// at all. That is a platform gap, not an engine one — but it only bites
// backends that tokenize in Dart. `flutter_gemma_litertlm`'s web arm does not:
// it tokenizes inside `sentencepiece.js`, part of its own JS bundle, and never
// reaches this file.
//
// So this refuses SentencePiece loudly rather than falling through to a
// tokenizer with the wrong convention, which would return vectors that are
// quietly the wrong point in the embedding space.

import 'dart:js_interop';

import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart'
    show EmbeddingTokenizer;

import '../wordpiece_tokenizer_json.dart' show parseWordPieceTokenizerJson;

@JS('fetch')
external JSPromise<_FetchResponse> _fetchJs(JSString url);

extension type _FetchResponse._(JSObject _) implements JSObject {
  external JSBoolean get ok;
  external JSNumber get status;
  external JSPromise<JSString> text();
}

/// Fetches the `tokenizer.json` at [tokenizerPath] and parses it.
///
/// Signature-compatible with the native arm (`EmbeddingTokenizerFactory` takes
/// a path; on web that path is a URL), so a backend passes the same tear-off
/// on both platforms and neither has to branch.
Future<EmbeddingTokenizer> resolveEmbeddingTokenizer(
  String tokenizerPath,
) async {
  final response = await _fetchJs(tokenizerPath.toJS).toDart;
  if (!response.ok.toDart) {
    throw StateError(
      'Failed to fetch the tokenizer at "$tokenizerPath": '
      'HTTP ${response.status.toDartInt}',
    );
  }
  return parseWordPieceTokenizerJson((await response.text().toDart).toDart);
}
