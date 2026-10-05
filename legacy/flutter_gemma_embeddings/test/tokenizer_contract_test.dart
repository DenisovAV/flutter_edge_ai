@TestOn('vm')
library;

// Covers the enforcement half of the bare-content contract.
//
// No fixture can reach it: on every version the constraint admits, `noPadding()`
// and `noTruncation()` are unconditional field-nulls, so after the loader's
// cascade both getters are null for ANY file. That is why the guard was an
// equivalent mutant when it lived inline in `loadEmbeddingTokenizer` — deleting
// it left the suite green, and so did flipping its `||` to `&&`. Measured.
//
// The input to check is a tokenizer, not a file, so the fake is a tokenizer:
// one that accepts the disable calls and ignores them, which is precisely the
// upstream release this exists to catch.
//
// KNOWN GAP, measured: these tests pin the CHECK, not the fact that
// `loadEmbeddingTokenizer` calls it. Deleting that one call still leaves the
// suite green. Closing it needs an injectable loader on the public function's
// signature, which would make the release a minor; the call is one line, in
// plain sight, directly under the comment that explains it.

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter_gemma_embeddings/src/tokenizer_contract.dart';
import 'package:flutter_test/flutter_test.dart';

/// A future `dart_sentencepiece_tokenizer` whose `noPadding()`/`noTruncation()`
/// have been deprecated to no-ops: the config the caller asked to clear is
/// still there afterwards.
class _NoOpDisableTokenizer implements SentencePieceTokenizer {
  _NoOpDisableTokenizer({this.padding, this.truncation});

  @override
  final SpPaddingConfig? padding;

  @override
  final SpTruncationConfig? truncation;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const path = '/models/siglip2/tokenizer.json';

  test('padding left applied is rejected, and named', () {
    expect(
      () => requireBareContent(
        _NoOpDisableTokenizer(padding: const SpPaddingConfig(length: 64)),
        path,
      ),
      throwsA(
        isA<StateError>()
            .having((e) => e.message, 'message', contains('padding'))
            .having((e) => e.message, 'path', contains(path)),
      ),
    );
  });

  test('truncation left applied is rejected on its own', () {
    // The case that dies first under a boolean condition: with `&&` instead of
    // `||`, a release that no-ops only ONE of the two methods sails through.
    // This test is the reason the check collects offenders instead.
    expect(
      () => requireBareContent(
        _NoOpDisableTokenizer(
          truncation: const SpTruncationConfig(maxLength: 8),
        ),
        path,
      ),
      throwsA(
        isA<StateError>()
            .having((e) => e.message, 'message', contains('truncation'))
            .having(
              (e) => e.message,
              'not padding',
              isNot(contains('padding')),
            ),
      ),
    );
  });

  test('both left applied are reported together', () {
    expect(
      () => requireBareContent(
        _NoOpDisableTokenizer(
          padding: const SpPaddingConfig(length: 64),
          truncation: const SpTruncationConfig(maxLength: 8),
        ),
        path,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('padding'), contains('truncation')),
        ),
      ),
    );
  });

  test('a tokenizer that honoured the calls passes through untouched', () {
    final tokenizer = _NoOpDisableTokenizer();

    // Identity, not just "did not throw": the loader returns whatever this
    // hands back, so swapping the instance here would silently discard the
    // configured tokenizer the caller actually loaded.
    expect(requireBareContent(tokenizer, path), same(tokenizer));
  });
}
