// Enforcement for the bare-content contract `loadEmbeddingTokenizer` promises.
//
// Deliberately NOT re-exported from `lib/embedding_tokenizer.dart` (which
// blanket-exports its `src/` file): this is an internal check, and adding a
// public symbol would make the release a minor rather than a patch. Tests reach
// it by importing this `src/` path directly, the way the loader-contract test
// already imports `src/embedding_tokenizer.dart`.

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';

/// Verifies that [tokenizer] will hand back BARE content, and returns it.
///
/// `loadEmbeddingTokenizer` calls `noPadding()`/`noTruncation()`; this checks
/// they took effect, on the user's machine, at load, once per model.
///
/// What it catches, precisely: a release where those two methods stop clearing
/// the config they name — deprecated to no-ops, or refactored to return a new
/// instance while leaving the receiver untouched (the `..` cascade discards the
/// copy, so the original stays configured and this sees it). A RENAME instead
/// fails at compile time, which is why this only has to cover the silent shapes.
///
/// What it does NOT catch: a release that pads or truncates through some THIRD
/// field, leaving both of these null. Nothing here can see that — only a
/// behavioural assertion on `encode()`'s output can, which is what
/// `test/siglip_loader_contract_test.dart` is for. The two are complementary,
/// and neither subsumes the other.
SentencePieceTokenizer requireBareContent(
  SentencePieceTokenizer tokenizer,
  String tokenizerPath,
) {
  // Collected as a list rather than tested with `||`: there is then no operator
  // to get backwards. When this was a boolean, an `&&` typo — which would let a
  // release that no-ops just ONE of the two calls through — was invisible to the
  // whole suite. `tokenizer_contract_test.dart` covers that case now; the shape
  // makes it unrepresentable.
  final stillApplied = <String>[
    if (tokenizer.padding != null) 'padding',
    if (tokenizer.truncation != null) 'truncation',
  ];
  if (stillApplied.isEmpty) return tokenizer;

  throw StateError(
    'dart_sentencepiece_tokenizer still applies ${stillApplied.join(' and ')} '
    'after noPadding()/noTruncation() for "$tokenizerPath". encode() would '
    'return padded or truncated content, and both embedding profiles append '
    'their own terminator after whatever they are handed — stranding it past '
    'the pad run and silently changing every vector, since SigLIP 2 pools the '
    'last position. Pin dart_sentencepiece_tokenizer to a version that honours '
    'these calls; 1.4.1 is known good.',
  );
}
