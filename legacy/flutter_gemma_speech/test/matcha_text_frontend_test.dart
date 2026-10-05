import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/tts/matcha_text_frontend.dart';
import 'package:flutter_gemma_speech/src/tts/tts_frontend_input.dart';
import 'package:flutter_gemma_speech/src/tts/tts_text_frontend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Tiny table WITH a space symbol (unlike the fixture in
  // tts_text_frontend_test.dart) so a multi-word chunk round-trips through
  // the normalizer's SymbolToken(' ') without hitting the fail-loud
  // unmapped-symbol throw.
  // Distinguishable per-slot values (0, 1, 2, ...) rather than an all-zero
  // table, so a comparison over symbolEmbeddings actually pins pid values/
  // order instead of trivially matching two all-zero arrays regardless of
  // which phoneme-ids were gathered.
  final embeddingTable = Float32List.fromList([
    for (var i = 0; i < 5 * 2; i++) i.toDouble(),
  ]);

  MatchaTextFrontend fe({
    NeuralG2pResolver? g2p,
    Map<String, String>? dictionary,
    int maxText = 16,
  }) => MatchaTextFrontend(
    symbolToId: {'_': 0, ' ': 1, '.': 2, 'a': 3, 'b': 4},
    dictionary: dictionary ?? {'ab': 'ab'},
    embeddingTable: embeddingTable,
    nChannels: 2,
    maxText: maxText,
    neuralG2p: g2p,
  );

  test('known word + trailing period recompose (symbols kept)', () {
    // normalize('ab.') -> [WordToken(ab), SymbolToken(.)] -> dict['ab']
    // + '.' recomposed as "ab." -> IPA runes [a,b,.] -> pids [3,4,2] ->
    // realLen = 2*3 + 1 = 7.
    final o = fe().encode('ab.');
    expect(o, isA<MatchaFrontendInput>());
    expect(o.realLen, 7);
  });

  test('OOV word routes through neural resolver', () {
    var called = '';
    final o = fe(
      g2p: (w) {
        called = w;
        return 'ab';
      },
    ).encode('zz');
    expect(called, 'zz');
    expect(o.realLen, greaterThan(0));
  });

  test('OOV word with no resolver throws', () {
    expect(() => fe().encode('zz'), throwsA(isA<StateError>()));
  });

  test(
    'non-speech chunk (no symbols mapped) returns empty input, not a throw',
    () {
      // '👍' is not a letter, not whitespace, and not in the tiny symbol
      // table, so the normalizer drops it entirely -> zero tokens -> zero
      // pids. encode() must return a defined empty MatchaFrontendInput
      // (realLen 0) instead of throwing, so the worker's `realLen <= 1`
      // guard can skip this clause without erroring the whole request.
      final o = fe().encode('👍');
      expect(o, isA<MatchaFrontendInput>());
      expect(o.realLen, 0);
      expect(o.symbolEmbeddings, isEmpty);
      expect(o.textMask, isEmpty);
    },
  );

  group('encodeChunks', () {
    test(
      'golden-safe: fitting text returns a single input equal to encode()',
      () {
        final frontend = fe();
        final golden = frontend.encode('ab.');
        final chunks = frontend.encodeChunks('ab.');
        expect(chunks, hasLength(1));
        expect(chunks.single.realLen, golden.realLen);
        expect(chunks.single.textMask, golden.textMask);
        expect(chunks.single.symbolEmbeddings, golden.symbolEmbeddings);
      },
    );

    test('splits an over-long clause at word boundaries; every chunk fits '
        'MAX_TEXT and nothing throws', () {
      // maxText=16 -> maxPids=(16-1)~/2=7. "ab ab ab ab" is 4 words
      // (2 pids each) joined by 3 single-pid space tokens (this fixture
      // maps ' ' to a symbol id) = 11 pids total, no internal clause
      // punctuation, so encode() overflows MAX_TEXT (realLen 23 > 16).
      const text = 'ab ab ab ab';
      final frontend = fe();
      expect(() => frontend.encode(text), throwsA(isA<StateError>()));

      final chunks = frontend.encodeChunks(text);
      expect(chunks.length, greaterThan(1));
      for (final c in chunks) {
        expect(c.realLen, lessThanOrEqualTo(16));
      }
    });

    test('word-boundary integrity: total phoneme count is conserved across '
        'the split (no phoneme lost or duplicated)', () {
      const text = 'ab ab ab ab';
      final small = fe(); // maxText 16 -> splits.
      // Reference frontend with a MAX_TEXT large enough that the whole
      // text fits a single encode() call -> its realLen is the
      // ground-truth whole-text phoneme count.
      final big = fe(maxText: 1000);
      final wholePids = (big.encode(text).realLen - 1) ~/ 2;

      final chunks = small.encodeChunks(text);
      final splitPids = chunks.fold<int>(
        0,
        (sum, c) => sum + (c.realLen - 1) ~/ 2,
      );
      expect(splitPids, wholePids);
    });

    test('a single token whose phonemes alone exceed MAX_TEXT still throws '
        '(genuine limit, cannot split mid-word)', () {
      // 'longword' -> 8 a's = 8 pids > maxPids=7 (maxText=16): a single
      // token cannot be split at a word boundary without breaking G2P.
      final frontend = fe(dictionary: {'ab': 'ab', 'longword': 'aaaaaaaa'});
      expect(
        () => frontend.encodeChunks('longword'),
        throwsA(isA<StateError>()),
      );
    });

    test('all-non-speech input returns a list of ONE empty input, not an '
        'empty list (the worker\'s realLen <= 1 skip depends on a non-empty '
        'list to iterate)', () {
      // '👍' maps to zero tokens in this tiny symbol table (same fixture
      // as the encode() non-speech test above) -> every per-token pids
      // list is empty -> encodeChunks' `result` stays empty -> the
      // all-non-speech fallback must kick in.
      final chunks = fe().encodeChunks('👍');
      expect(chunks, hasLength(1));
      expect(chunks.single.realLen, 0);
      expect(chunks.single.symbolEmbeddings, isEmpty);
      expect(chunks.single.textMask, isEmpty);
    });
  });
}
