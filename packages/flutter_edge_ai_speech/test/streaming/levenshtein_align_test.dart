// Copyright 2026 The ODML Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Modified: ported from C++ (LiteRT-LM v0.19.1,
// omni/speech2text/levenshtein_align_test.cc) to Dart for
// flutter_edge_ai_speech.
//
// Every upstream case is ported with its inputs and expected values.

import 'package:flutter_edge_ai_speech/src/streaming/levenshtein_align.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LevenshteinAlignTest', () {
    test('EmptyInputs', () {
      expect(alignTokens([], []), isEmpty);
    });

    test('ExactMatch', () {
      expect(alignTokens(['hello', 'world'], ['hello', 'world']), [
        AlignCode.correct,
        AlignCode.correct,
      ]);
    });

    test('OverlapWithPrefixAndSuffix', () {
      expect(
        alignTokens(
          ['hello', 'world', 'this', 'is'],
          ['this', 'is', 'a', 'test'],
        ),
        [
          AlignCode.deletion,
          AlignCode.deletion,
          AlignCode.correct,
          AlignCode.correct,
          AlignCode.insertion,
          AlignCode.insertion,
        ],
      );
    });

    test('ComputeLevenshteinDistance', () {
      expect(computeLevenshteinDistanceStr('kitten', 'sitting'), 3);
      expect(computeLevenshteinDistanceStr('hello', 'hello'), 0);
      expect(computeLevenshteinDistanceStr('', 'abc'), 3);
      expect(computeLevenshteinDistanceStr('abc', ''), 3);

      expect(
        computeLevenshteinDistanceWords(['hello', 'world'], ['hella', 'world']),
        0,
      );
    });

    test('Canonicalize', () {
      expect(canonicalizeStr('Hello,'), 'hello');
      expect(canonicalizeWords(['Hello,', 'WORLD!']), ['hello', 'world']);
    });

    test('CloseEnoughTest', () {
      expect(closeEnoughCanonical('cat', 'cat'), isTrue);
      expect(closeEnoughCanonical('cat', 'car'), isFalse);
      expect(closeEnoughCanonical('hello', 'hella'), isTrue);
      expect(closeEnoughCanonical('hello', 'heyyy'), isFalse);

      expect(closeEnoughStr('cat', 'cat'), isTrue);
      // min_len <= 3 requiring exact prefix match
      expect(closeEnoughStr('cat', 'car'), isFalse);
      // min_len > 3 with dist <= 1
      expect(closeEnoughStr('hello', 'hella'), isTrue);
      expect(closeEnoughStr('hello', 'heyyy'), isFalse);
    });

    test('CloseEnoughSpansTest', () {
      expect(closeEnoughWords(['hello', 'world'], ['hella', 'world']), isTrue);
      expect(closeEnoughWords(['hello', 'world'], ['hello']), isFalse);
    });

    test('DedupWordsTest', () {
      expect(
        dedupWords(
          ['the', 'stale', 'smell', 'of'],
          ['smell', 'of', 'old', 'beer'],
        ),
        ['old', 'beer'],
      );
    });

    test('FindBestSeamMatchRunPrefersLongestContiguousRun', () {
      final prev = ['read', 'the', 'book', 'on', 'the', 'table', 'today'];
      final curr = ['the', 'the', 'table', 'today', 'please'];
      expect(findBestSeamMatchRun(prev, 0, curr, curr.length), [
        (4, 1),
        (5, 2),
        (6, 3),
      ]);
    });

    test('FindBestSeamMatchRunFallsBackToDirectBoundaryScan', () {
      // Global edit distance pairs scattered single matches across
      // substitutions, while the boundary has a 2-word contiguous run ("right
      // now").
      final prev = ['a', 'x1', 'b', 'x2', 'c', 'x3', 'right', 'now'];
      final curr = ['right', 'now', 'a', 'y1', 'b', 'y2', 'c', 'y3'];
      expect(findBestSeamMatchRun(prev, 0, curr, curr.length), [
        (6, 0),
        (7, 1),
      ]);
    });

    test('FindBestSeamMatchRunFindsGappedPairWithContentWord', () {
      // "didn't" vs "did not" splits the boundary overlap into two aligned
      // matches ("really" and "understand") separated by a small gap.
      final prev = ['we', 'really', "didn't", 'understand'];
      final curr = ['really', 'did', 'not', 'understand', 'it'];
      expect(findBestSeamMatchRun(prev, 0, curr, curr.length), [
        (1, 0),
        (3, 3),
      ]);
    });

    test('FindBestSeamMatchRunValidatesSingleWordMatches', () {
      // A single-word match right at the end of `prev` and start of `curr` is
      // kept.
      final prev = ['alpha', 'bravo', 'charlie'];
      final curr = ['charlie', 'delta', 'echo'];
      expect(findBestSeamMatchRun(prev, 0, curr, curr.length), [(2, 0)]);

      // An interior single-word stopword match is rejected.
      final prevInterior = ['alpha', 'the', 'bravo', 'charlie'];
      final currInterior = ['delta', 'echo', 'the', 'foxtrot'];
      expect(
        findBestSeamMatchRun(
          prevInterior,
          0,
          currInterior,
          currInterior.length,
        ),
        isEmpty,
      );
    });

    test('CanonicalizeStripsCjkAndUnicodePunctuation', () {
      expect(canonicalizeStr('吗？'), '吗');
      expect(canonicalizeStr('「中文」。'), '中文');
      expect(canonicalizeStr('“Hello,”—World!'), 'helloworld');
    });
  });
}
