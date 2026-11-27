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
// omni/speech2text/levenshtein_text_merger_test.cc) to Dart for
// flutter_edge_ai_speech.
//
// Every upstream case is ported with its inputs and expected values. The C++
// tests push words into a dummy stage and pull the merger's output; here
// `add` takes the words and returns the output.

import 'package:flutter_edge_ai_speech/src/streaming/detokenizer.dart';
import 'package:flutter_edge_ai_speech/src/streaming/levenshtein_text_merger.dart';
import 'package:flutter_test/flutter_test.dart';

List<DetokenizedWord> _words(List<String> strings) => [
  for (final s in strings) DetokenizedWord(s),
];

void main() {
  group('LevenshteinTextMergerTest', () {
    test('InitialChunkReturnsUnconfirmedOnly', () {
      final merger = LevenshteinTextMerger();

      final result = merger.add(_words(['hello', 'world']));

      expect(result.confirmed, '');
      expect(result.unconfirmed, 'hello world');
    });

    test('SequentialMergeFlow', () {
      final merger = LevenshteinTextMerger();

      // Chunk 1: "hello world this is"
      final res1 = merger.add(_words(['hello', 'world', 'this', 'is']));
      expect(res1.confirmed, '');
      expect(res1.unconfirmed, 'hello world this is');

      // Chunk 2: overlaps at "this is", adds "a test"
      final res2 = merger.add(_words(['this', 'is', 'a', 'test']));
      expect(res2.confirmed, 'hello world');
      expect(res2.unconfirmed, 'this is a test');

      // Chunk 3: overlaps at "a test", adds "of streaming"
      final res3 = merger.add(_words(['a', 'test', 'of', 'streaming']));
      expect(res3.confirmed, 'this is');
      expect(res3.unconfirmed, 'a test of streaming');

      // End of stream flush
      final flushText = merger.flush();
      expect(flushText, isNotNull);
      expect(flushText?.confirmed, 'a test of streaming');
      expect(flushText?.unconfirmed, '');
    });

    test('ResetClearsState', () {
      final merger = LevenshteinTextMerger();

      merger.add(_words(['hello', 'world']));
      expect(merger.unconfirmedWordsForTesting, isNotEmpty);

      merger.reset();
      expect(merger.unconfirmedWordsForTesting, isEmpty);

      // First merge after reset behaves as initial chunk
      final result = merger.add(_words(['new', 'stream']));
      expect(result.confirmed, '');
      expect(result.unconfirmed, 'new stream');
    });

    test('NoOverlapConfirmsPreviousState', () {
      final merger = LevenshteinTextMerger();

      merger.add(_words(['apple', 'banana']));

      // Chunk 2 has no overlap
      final result = merger.add(_words(['cat', 'dog']));
      expect(result.confirmed, 'apple banana');
      expect(result.unconfirmed, 'cat dog');
    });

    test('StitchesAtLongestContiguousOverlapMatch', () {
      final merger = LevenshteinTextMerger();

      // Chunk 1 has an earlier "the" and ends with "of the project".
      merger.add(
        _words([
          'are',
          'they',
          'happy',
          'with',
          'the',
          'progress',
          'of',
          'the',
          'project',
        ]),
      );

      // Chunk 2 starts with a noisy token "with", then matches "of the
      // project".
      final res2 = merger.add(
        _words(['with', 'of', 'the', 'project', 'they', 'might', 'not', 'be']),
      );
      expect(res2.confirmed, 'are they happy with the progress');
      expect(res2.unconfirmed, 'of the project they might not be');
    });

    test(
      'FallsBackToContiguousSeamRunWhenGlobalAlignmentScattersSingleMatches',
      () {
        final merger = LevenshteinTextMerger();

        // Global edit distance between chunk 1 and chunk 2 can pair scattered
        // tokens ("a", "b", "c") interleaved with substitutions so no
        // contiguous kCorrect run in `align_codes` has length >= 2, even
        // though the seam has an exact 2-word contiguous match ("right now")
        // at the end of chunk 1 / start of chunk 2.
        merger.add(_words(['a', 'x1', 'b', 'x2', 'c', 'x3', 'right', 'now']));

        final res2 = merger.add(
          _words(['right', 'now', 'a', 'y1', 'b', 'y2', 'c', 'y3']),
        );
        expect(res2.confirmed, 'a x1 b x2 c x3');
        expect(res2.unconfirmed, 'right now a y1 b y2 c y3');
      },
    );

    test('IgnoresInteriorSingleWordStopwordMatch', () {
      final merger = LevenshteinTextMerger();

      merger.add(_words(['alpha', 'the', 'bravo', 'charlie']));

      // Only "the" matches, and it is neither at the end of chunk 1 nor a
      // >=5-char boundary token, so no false stitch should drop "bravo
      // charlie".
      final res2 = merger.add(_words(['delta', 'echo', 'the', 'foxtrot']));
      expect(res2.confirmed, 'alpha the bravo charlie');
      expect(res2.unconfirmed, 'delta echo the foxtrot');
    });

    test('ChineseWindowsWithoutSpacesAreNotDuplicated', () {
      final merger = LevenshteinTextMerger();

      merger.add(_words(['你好吗？北京有什么好玩的？']));
      final res2 = merger.add(_words(['北京有什么好玩的？这个秋天还可以。']));

      expect(res2.confirmed, '你好吗？');
      expect(res2.unconfirmed, '北京有什么好玩的？这个秋天还可以。');
    });

    test('EmptyChunkKeepsUnconfirmedWords', () {
      final merger = LevenshteinTextMerger();

      merger.add(_words(['你好吗？']));
      final res2 = merger.add(_words([]));

      expect(res2.confirmed, '');
      expect(res2.unconfirmed, '你好吗？');
    });
  });
}
