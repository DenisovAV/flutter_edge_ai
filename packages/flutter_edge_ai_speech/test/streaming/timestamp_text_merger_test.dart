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
// omni/speech2text/timestamp_text_merger_test.cc) to Dart for
// flutter_edge_ai_speech.
//
// Every upstream case is ported with its inputs and expected values. The C++
// tests push words into a dummy stage and pull the merger's output; here
// `add` takes the words and returns the output, and `flush` returns the
// output the C++ Flush() pushes.

import 'package:flutter_edge_ai_speech/src/streaming/detokenizer.dart';
import 'package:flutter_edge_ai_speech/src/streaming/text_merger.dart';
import 'package:flutter_edge_ai_speech/src/streaming/timestamp_text_merger.dart';
import 'package:flutter_test/flutter_test.dart';

List<DetokenizedWord> _words(List<String> strings) => [
  for (final s in strings) DetokenizedWord(s),
];

List<DetokenizedWord> _withTimestamps(List<(String, int)> pairs) => [
  for (final (text, ts) in pairs) DetokenizedWord(text, timestampMs: ts),
];

List<DetokenizedWord> _withEndOfChunk(
  List<(String, int)> pairs,
  int endTsMs, {
  bool isWarmStart = false,
}) => [
  ..._withTimestamps(pairs),
  DetokenizedWord.endOfChunk(timestampMs: endTsMs, isWarmStart: isWarmStart),
];

MergeResult _flush(TimestampTextMerger merger) {
  final result = merger.flush();
  expect(result, isNotNull, reason: 'Flush() pushed no output');
  return result ?? const MergeResult('', '');
}

// Runs `windows` (one space-free CJK hypothesis per window, as emitted by
// Qwen3-ASR) through `merger` and returns all confirmed text plus the flush.
String _mergeWindows(TimestampTextMerger merger, List<String> windows) {
  final text = StringBuffer();
  for (final window in windows) {
    text.write(merger.add(_words([window])).confirmed);
  }
  text.write(_flush(merger).confirmed);
  return text.toString();
}

void main() {
  group('TimestampTextMergerTest', () {
    test('InitialChunkReturnsUnconfirmedOnly', () {
      final merger = TimestampTextMerger();

      final result = merger.add(_words(['hello', 'world']));

      expect(result.confirmed, '');
      expect(result.unconfirmed, 'hello world');
    });

    test('SequentialMergeFlowWithTimestamps', () {
      final merger = TimestampTextMerger(overlapRatio: 0.5);

      // Chunk 1 (0 to 5000 ms)
      final res1 = merger.add(
        _withTimestamps([
          ('the', 500),
          ('stale', 1000),
          ('smell', 1500),
          ('of', 2000),
          ('old', 2500),
          ('beer', 3000),
          ('lingers', 3500),
        ]),
      );
      expect(res1.confirmed, '');
      expect(res1.unconfirmed, 'the stale smell of old beer lingers');

      // Chunk 2 (2500 ms to 7500 ms relative to start of Chunk 2)
      final res2 = merger.add(
        _withTimestamps([
          ('old', 0),
          ('beer', 500),
          ('lingers', 1000),
          ('it', 1500),
          ('takes', 2000),
          ('heat', 2500),
        ]),
      );
      expect(res2.confirmed, isNotEmpty);
      expect(res2.unconfirmed, isNotEmpty);

      final resFlush = _flush(merger);
      expect(resFlush.confirmed, isNotEmpty);
      expect(resFlush.unconfirmed, '');
    });

    test('ResetClearsState', () {
      final merger = TimestampTextMerger();

      merger.add(_words(['hello', 'world']));
      expect(merger.unconfirmedWordsForTesting, isNotEmpty);

      merger.reset();
      expect(merger.unconfirmedWordsForTesting, isEmpty);

      final result = merger.add(_words(['new', 'stream']));
      expect(result.confirmed, '');
      expect(result.unconfirmed, 'new stream');
    });

    test('SequentialMergeFlowUsesEndOfChunkTimestampForStep', () {
      final merger = TimestampTextMerger(overlapRatio: 0.5);

      // Chunk 1 has 5000 ms total duration (end of chunk ts = 5000)
      merger.add(
        _withEndOfChunk([
          ('the', 500),
          ('stale', 1000),
          ('smell', 1500),
          ('of', 2000),
          ('old', 2500),
          ('beer', 3000),
          ('lingers', 3500),
        ], 5000),
      );

      // Chunk 2 starts at 2500 ms relative to start of Chunk 2
      final res2 = merger.add(
        _withEndOfChunk([
          ('old', 0),
          ('beer', 500),
          ('lingers', 1000),
          ('it', 1500),
          ('takes', 2000),
          ('heat', 2500),
        ], 5000),
      );
      expect(res2.confirmed, isNotEmpty);
      expect(res2.unconfirmed, isNotEmpty);
    });

    test('ReplacesEndOfChunkHallucinationWithGroundTruth', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 has hallucinated "huge" at the end of chunk
      final res1 = merger.add(
        _withEndOfChunk([
          ('the', 1000),
          ('stale', 1600),
          ('smell', 2100),
          ('of', 2600),
          ('old', 3000),
          ('beer', 3400),
          ('lingers', 4100),
          ('it', 4600),
          ('takes', 5000),
          ('huge', 5400),
        ], 5500),
      );
      expect(res1.confirmed, '');

      // Chunk 2 decodes ground truth "heat" at 1800 ms
      final res2 = merger.add(
        _withEndOfChunk([
          ('lingers', 300),
          ('it', 800),
          ('takes', 1300),
          ('heat', 1800),
          ('to', 2300),
          ('bring', 2700),
          ('out', 2800),
        ], 5500),
      );
      expect(res2.confirmed, 'the stale smell of old beer');
      expect(res2.unconfirmed, 'lingers it takes heat to bring out');

      final resFlush = _flush(merger);
      expect(resFlush.confirmed, 'lingers it takes heat to bring out');
      expect(resFlush.unconfirmed, '');
    });

    test('SilencePausePreventsMisalignment', () {
      final merger = TimestampTextMerger(overlapRatio: 0.5);

      // Chunk 1 ends early with last word at 1000ms
      merger.add(_withEndOfChunk([('hello', 500), ('world', 1000)], 5000));

      // Chunk 2 starts after long silence (first word at 4500ms). Its window
      // starts at 2500 ms, after both words of chunk 1, which are therefore
      // final.
      final res2 = merger.add(
        _withEndOfChunk([('hello', 4500), ('again', 4800)], 5000),
      );
      expect(res2.confirmed, 'hello world');
      expect(res2.unconfirmed, 'hello again');

      final resFlush = _flush(merger);
      expect(resFlush.confirmed, 'hello again');
      expect(resFlush.unconfirmed, '');
    });

    test('KeepsPreviousWordsMissingFromCurrentChunkStart', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      merger.add(
        _withEndOfChunk([
          ('the', 500),
          ('stale', 1000),
          ('smell', 2000),
          ('of', 2500),
          ('old', 3200),
          ('beer', 3600),
          ('lingers', 4000),
          ('it', 4400),
          ('takes', 4800),
        ], 5000),
      );

      // Chunk 2 (from 3000 ms) did not recognize "old beer" at its start.
      final res2 = merger.add(
        _withEndOfChunk([
          ('lingers', 1000),
          ('it', 1400),
          ('takes', 1800),
          ('heat', 2200),
        ], 5000),
      );
      expect(res2.confirmed, 'the stale smell of');
      expect(res2.unconfirmed, 'old beer lingers it takes heat');
    });

    test('KeepsPreviousTailWhereCurrentChunkHasGap', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      merger.add(
        _withEndOfChunk([
          ('the', 500),
          ('stale', 1000),
          ('smell', 2000),
          ('of', 2500),
          ('old', 3200),
          ('beer', 3600),
          ('lingers', 4000),
          ('it', 4100),
          ('takes', 4500),
          ('heat', 4700),
        ], 5000),
      );

      // Chunk 2 (from 3000 ms) heard nothing between "it" and "to": the
      // previous chunk's "takes heat" is kept and the new word "to" is added.
      final res2 = merger.add(
        _withEndOfChunk([
          ('old', 200),
          ('beer', 600),
          ('lingers', 1000),
          ('it', 1100),
          ('to', 2600),
        ], 5000),
      );
      expect(res2.confirmed, 'the stale smell of');
      expect(res2.unconfirmed, 'old beer lingers it takes heat to');
    });

    test('CurrentChunkWinsAfterPivotWhereItHeardWords', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // "ta kes" at the end of chunk 1 was heard as two words.
      merger.add(
        _withEndOfChunk([
          ('the', 500),
          ('stale', 1000),
          ('smell', 2000),
          ('of', 2500),
          ('old', 3200),
          ('beer', 3600),
          ('lingers', 4000),
          ('it', 4300),
          ('ta', 4600),
          ('kes', 4800),
        ], 5000),
      );

      final res2 = merger.add(
        _withEndOfChunk([
          ('old', 200),
          ('beer', 600),
          ('lingers', 1000),
          ('it', 1300),
          ('takes', 1700),
          ('heat', 2200),
        ], 5000),
      );
      expect(res2.confirmed, 'the stale smell of');
      expect(res2.unconfirmed, 'old beer lingers it takes heat');
    });

    test('ChunkAfterEmptyWindowConfirmsPreviousWords', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      merger.add(_withEndOfChunk([('hello', 500), ('world', 1000)], 5000));

      // Chunk 2 (3000-8000 ms) is silent.
      final res2 = merger.add(_withEndOfChunk([], 5000));
      expect(res2.confirmed, '');
      expect(res2.unconfirmed, 'hello world');

      // Chunk 3 (6000-11000 ms) does not overlap the window of "hello world".
      final res3 = merger.add(
        _withEndOfChunk([('new', 500), ('words', 900)], 5000),
      );
      expect(res3.confirmed, 'hello world');
      expect(res3.unconfirmed, 'new words');
    });

    test('PartialWordAtWindowStartIsDropped', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      merger.add(
        _withEndOfChunk([
          ('the', 500),
          ('quick', 1000),
          ('brown', 1500),
          ('fox', 2000),
          ('jumps', 2900),
          ('over', 3400),
          ('the', 3800),
          ('lazy', 4200),
          ('dog', 4600),
        ], 5000),
      );

      // Chunk 2 starts at 3000 ms, in the middle of "jumps", and decodes its
      // tail.
      final res2 = merger.add(
        _withEndOfChunk([
          ('umps', 0),
          ('over', 400),
          ('the', 800),
          ('lazy', 1200),
          ('dog', 1600),
          ('and', 2200),
          ('runs', 2600),
        ], 5000),
      );
      expect(res2.confirmed, 'the quick brown fox jumps');
      expect(res2.unconfirmed, 'over the lazy dog and runs');
    });

    test('StreamOffsetKeepsFractionalStep', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Encoder-frame timestamps: 63 frames per chunk, step 37.8 frames.
      for (var i = 0; i < 5; ++i) {
        merger.add(_withEndOfChunk([('word', 10)], 63));
      }
      expect(merger.streamTimestampOffsetForTesting, closeTo(5 * 37.8, 0.01));
    });

    test('RepeatedWordsHandlingWithTimestamps', () {
      final merger = TimestampTextMerger(overlapRatio: 0.5);

      // Repeated words "the the the" with distinct timestamps
      merger.add(
        _withEndOfChunk([
          ('the', 500),
          ('the', 1500),
          ('the', 2500),
          ('end', 3000),
        ], 5000),
      );

      merger.add(
        _withEndOfChunk([('the', 0), ('end', 500), ('next', 1000)], 5000),
      );

      final resFlush = _flush(merger);
      expect(resFlush.confirmed, 'the end next');
      expect(resFlush.unconfirmed, '');
    });

    test('EmptyChunkWithEndOfChunkSentinelRetainsUnconfirmedWords', () {
      final merger = TimestampTextMerger(overlapRatio: 0.5);

      final res1 = merger.add(
        _withEndOfChunk([('hello', 500), ('world', 1000)], 5000),
      );
      expect(res1.unconfirmed, 'hello world');

      // Chunk 2 has only the end-of-chunk sentinel (no spoken words).
      final res2 = merger.add(_withEndOfChunk([], 5000));
      expect(res2.confirmed, '');
      expect(res2.unconfirmed, 'hello world');
    });

    test('SequentialMergeFlowWithoutTimestamps', () {
      final merger = TimestampTextMerger(overlapRatio: 0.5);

      final res1 = merger.add(_words(['hello', 'world', 'this', 'is']));
      expect(res1.confirmed, '');
      expect(res1.unconfirmed, 'hello world this is');

      final res2 = merger.add(_words(['this', 'is', 'a', 'test']));
      expect(res2.confirmed, 'hello world');
      expect(res2.unconfirmed, 'this is a test');
    });

    test('ShortWordBetweenMatchedWordsBeforePivotIsPreserved', () {
      final merger = TimestampTextMerger(overlapRatio: 0.5);

      // Chunk 1 (frames 0..63): missed short word "I" between "were." (42)
      // and "know" (47). Both 42 and 47 are within tol.substitution (4.725
      // frames) of frame 44, but > 1.0 frame away.
      merger.add(
        _withEndOfChunk([
          ('as', 35),
          ('it', 38),
          ('were.', 42),
          ('know', 47),
          ('most', 52),
        ], 63),
      );

      // Chunk 2 (step=31.5 -> chunk_start_ms=32): decodes "were." (10 -> 42),
      // "I" (12 -> 44), "know" (15 -> 47), "most" (20 -> 52), "of" (24 ->
      // 56). Because "were." and "know" in prev are matched, they do not
      // suppress "I" (at 44 < pivot) via covered_by_prev.
      merger.add(
        _withEndOfChunk([
          ('as', 3),
          ('it', 6),
          ('were.', 10),
          ('I', 12),
          ('know', 15),
          ('most', 20),
          ('of', 24),
        ], 63),
      );

      final flushed = _flush(merger);
      expect(flushed.confirmed, 'as it were. I know most of');
    });

    test(
      'MergedTimestampsRemainSortedWhenShiftedCurrentOnlyWordPrecedesPair',
      () {
        final merger = TimestampTextMerger(overlapRatio: 0.4);

        // Chunk 1 (0-5000).
        merger.add(
          _withEndOfChunk([
            ('the', 500),
            ('stale', 1000),
            ('smell', 2000),
            ('alpha', 3200),
            ('beta', 3600),
            ('gamma', 3800),
            ('delta', 4400),
            ('eps', 4800),
          ], 5000),
        );

        // Chunk 2 (3000-8000) emits every shared word 300 ms later than chunk 1
        // (shift = +300) and hears an extra word "new" between "beta" and
        // "gamma".
        final res2 = merger.add(
          _withEndOfChunk([
            ('alpha', 500),
            ('beta', 900),
            ('new', 950),
            ('gamma', 1100),
            ('delta', 1700),
            ('eps', 2100),
            ('zeta', 2500),
            ('eta', 3300),
            ('theta', 3700),
          ], 5000),
        );
        expect(res2.confirmed, 'the stale smell');
        expect(
          res2.unconfirmed,
          'alpha beta new gamma delta eps zeta eta theta',
        );

        // Chunk 3 (6000-11000) hears "eta" but misses "theta" (gap) and adds
        // "kappa". With the time-based merge preserved, "theta" (6700 < pivot
        // 7200) is kept.
        final res3 = merger.add(
          _withEndOfChunk([('eta', 300), ('kappa', 3500)], 5000),
        );
        expect(res3.confirmed, 'alpha beta new gamma delta eps zeta');
        expect(res3.unconfirmed, 'eta theta kappa');
      },
    );

    test('SilentChunkWithoutSentinelAdvancesStreamOffset', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000).
      merger.add(
        _withEndOfChunk([
          ('the', 500),
          ('stale', 1000),
          ('smell', 2000),
          ('of', 2900),
          ('lingers', 4000),
          ('it', 4400),
          ('takes', 4800),
        ], 5000),
      );
      expect(merger.streamTimestampOffsetForTesting, closeTo(3000, 0.01));

      // Chunk 2 (3000-8000) is silent: no words, no end-of-chunk sentinel.
      merger.add(_words([]));
      expect(merger.streamTimestampOffsetForTesting, closeTo(6000, 0.01));

      // Chunk 3 (6000-11000): "the end" right after the silence.
      final res3 = merger.add(
        _withEndOfChunk([('the', 200), ('end', 600)], 5000),
      );
      expect(res3.confirmed, 'the stale smell of lingers it takes');
      expect(res3.unconfirmed, 'the end');
    });

    test('NewWordAtWindowStartNotDroppedAfterFullySpokenPreviousWord', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000) heard "fox" at 2900 ms, missed "over" at 3000 ms,
      // and heard "the lazy dog" at 3800..4600 ms.
      merger.add(
        _withEndOfChunk([
          ('the', 500),
          ('quick', 1000),
          ('brown', 1500),
          ('fox', 2900),
          ('the', 3800),
          ('lazy', 4200),
          ('dog', 4600),
        ], 5000),
      );

      // Chunk 2 (3000-8000) hears "over" at 0 ms (3000 ms absolute), which is
      // not a partial suffix of "fox" and should be preserved.
      final res2 = merger.add(
        _withEndOfChunk([
          ('over', 0),
          ('the', 800),
          ('lazy', 1200),
          ('dog', 1600),
        ], 5000),
      );
      expect(res2.confirmed, 'the quick brown fox');
      expect(res2.unconfirmed, 'over the lazy dog');
    });

    test('MissedWordAfterMatchedInWindowWordIsKept', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000) heard "the" at 3000 but missed "big" at 3250.
      merger.add(
        _withEndOfChunk([
          ('see', 500),
          ('the', 3000),
          ('lazy', 3800),
          ('dog', 4200),
        ], 5000),
      );

      // Chunk 2 (3000-8000) hears "the big lazy dog runs".
      final res2 = merger.add(
        _withEndOfChunk([
          ('the', 0),
          ('big', 250),
          ('lazy', 800),
          ('dog', 1200),
          ('runs', 2000),
        ], 5000),
      );
      expect(res2.confirmed, 'see');
      expect(res2.unconfirmed, 'the big lazy dog runs');
    });

    test('WordCountPrevTailBranchReseedsTimestamps', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 without timestamps.
      merger.add(_words(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']));

      // Chunk 2 (0-5000) with timestamps: only "e f g" (fewer words after the
      // pivot than the previous tail) -> MergeByWordCount, prev-tail branch.
      merger.add(_withEndOfChunk([('e', 100), ('f', 3500), ('g', 4000)], 5000));

      // Chunk 3 (3000-8000) with timestamps overlapping chunk 2's window:
      // hears "f" at 500 (3500 absolute) and "i" at 2500 (5500 absolute),
      // missing "g" and "h" (both synthesized at 4000 < pivot 4200). Because
      // chunk 2 re-seeded prev_timestamps_, chunk 3 uses MergeByTime and
      // preserves "g h" before the pivot.
      final res3 = merger.add(_withEndOfChunk([('f', 500), ('i', 2500)], 5000));
      expect(res3.confirmed, 'e');
      expect(res3.unconfirmed, 'f g h i');
    });

    test('EstimateTimestampShiftIgnoresSingleCharAndOutOfOverlapWords', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000): "early" is at 2800 ms (before chunk 2's 3000 ms
      // start), followed by three single-char tokens at 3100, 3500, 3900 and
      // two multi-char words at 4200 and 4600.
      merger.add(
        _withEndOfChunk([
          ('early', 2800),
          ('a', 3100),
          ('i', 3500),
          ('o', 3900),
          ('signal', 4200),
          ('detected', 4600),
        ], 5000),
      );

      // Chunk 2 (3000-8000): the three single-char tokens appear at +300 ms
      // (3400, 3800, 4200), whereas the multi-char words "signal" and
      // "detected" have zero shift (4200, 4600). Because single-char words are
      // ignored by EstimateTimestampShift, shift is 0 (chunk_start = 3000)
      // rather than +300 (which would lower chunk_start to 2700 and leave
      // "early" unconfirmed).
      final res2 = merger.add(
        _withEndOfChunk([
          ('a', 400),
          ('i', 800),
          ('o', 1200),
          ('signal', 1200),
          ('detected', 1600),
          ('now', 2500),
        ], 5000),
      );
      expect(res2.confirmed, 'early');
    });

    test('BoundaryFragmentSharingSubstringOrFollowingNumericWordIsDropped', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000): "station" starts at 2900 ms (just before chunk 2's
      // 3000 ms boundary).
      merger.add(
        _withEndOfChunk([
          ('next', 1000),
          ('station', 2900),
          ('ahead', 3800),
          ('now', 4400),
        ], 5000),
      );

      // Chunk 2 (3000-8000): hears cut fragment "ational" at 50 ms (3050 ms
      // absolute), which shares a 3-char substring ("ati"/"tio"/"ion") with
      // "station" at 2900 ms and is dropped by IsCutAtWindowStart.
      final res2 = merger.add(
        _withEndOfChunk([
          ('ational', 50),
          ('ahead', 800),
          ('now', 1400),
          ('please', 2200),
        ], 5000),
      );
      expect(res2.confirmed, 'next station');
      expect(res2.unconfirmed, 'ahead now please');

      // Also verify a boundary word following a numeric word at the window
      // start:
      merger.reset();
      merger.add(
        _withEndOfChunk([
          ('room', 1000),
          ('105', 2900),
          ('is', 3800),
          ('open', 4400),
        ], 5000),
      );

      // Chunk 2 hears "five" at 50 ms (3050 ms absolute) from the tail of
      // "105".
      final resNum = merger.add(
        _withEndOfChunk([
          ('five', 50),
          ('is', 800),
          ('open', 1400),
          ('today', 2200),
        ], 5000),
      );
      expect(resNum.confirmed, 'room 105');
      expect(resNum.unconfirmed, 'is open today');
    });

    test('DeduplicatesTrailingSuffixOfHyphenatedAndApostropheWords', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000) decodes "twenty-five" at 3400 ms and "it's" at 3900
      // ms.
      merger.add(
        _withEndOfChunk([
          ('count', 1000),
          ('twenty-five', 3400),
          ("it's", 3900),
          ('ready', 4400),
        ], 5000),
      );

      // Chunk 2 (3000-8000) pairs "twenty-five" (before pivot 4200, so kept
      // from prev) and also emits an unpaired trailing "five" at 4250 ms and
      // "s" right after "it's". AppendMergedWord deduplicates both trailing
      // suffixes.
      final res2 = merger.add(
        _withEndOfChunk([
          ('twenty-five', 400),
          ('five', 1250),
          ("it's", 1300),
          ('s', 1350),
          ('ready', 1400),
          ('now', 2200),
        ], 5000),
      );
      expect(res2.confirmed, 'count');
      expect(res2.unconfirmed, "twenty-five it's ready now");
    });

    test('PairedSubstitutionAtPivotPrefersPreviousNumericWord', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-63 frames, step=37.8, pivot=37.8 + 0.6*(63-37.8) = 52.92):
      // Numeric word "25" is at frame 53 (within pivot + 1.0).
      merger.add(
        _withEndOfChunk([
          ('page', 20),
          ('number', 42),
          ('is', 48),
          ('25', 53),
          ('today', 59),
        ], 63),
      );

      // Chunk 2 (chunk_start_ms=38) pairs at frame 53 with non-numeric
      // "twenty" (15 + 38 = 53). Because prev_ov_words[i] starts with a digit
      // and is within pivot + 1.0, "25" is preferred over "twenty".
      final res2 = merger.add(
        _withEndOfChunk([
          ('number', 4),
          ('is', 10),
          ('twenty', 15),
          ('today', 21),
          ('ok', 35),
        ], 63),
      );
      expect(res2.confirmed, 'page');
      expect(res2.unconfirmed, 'number is 25 today ok');
    });

    test('DropsShortUnpairedTailWordAtEndOfPreviousChunkWindow', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-63 frames) has a short 2-char truncated word "th" right at
      // the end of the chunk (frame 62 >= prev_end_ms - 1.0).
      merger.add(
        _withEndOfChunk([
          ('start', 20),
          ('reading', 42),
          ('now', 48),
          ('th', 62),
        ], 63),
      );

      // Chunk 2 (chunk_start_ms=38) hears "reading" (42), "now" (48), and
      // continues with "complete" at frame 75 (37 + 38), leaving "th" at 62
      // unpaired. Because "th" is a short (<= 3 chars) final word of chunk 1
      // at the window end, it is dropped rather than kept as a gap word.
      final res2 = merger.add(
        _withEndOfChunk([('reading', 4), ('now', 10), ('complete', 37)], 63),
      );
      expect(res2.confirmed, 'start');
      expect(res2.unconfirmed, 'reading now complete');
    });

    test('BoundaryWordFollowingNumericWordIsNotDroppedWhenNotAnEcho', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000): ends with "100" at 2900 ms.
      merger.add(_withEndOfChunk([('cost', 1000), ('100', 2900)], 5000));

      // Chunk 2 (3000-8000): begins with "dollars" at 50 ms (3050 ms
      // absolute). "dollars" is a valid word starting the next clause and not
      // a spoken echo of "100" (like "hundred"), so it must NOT be treated as
      // a cut fragment.
      final res = merger.add(
        _withEndOfChunk([
          ('dollars', 50),
          ('is', 800),
          ('due', 1400),
          ('today', 2200),
        ], 5000),
      );
      expect(res.confirmed, 'cost 100');
      expect(res.unconfirmed, 'dollars is due today');

      // Also verify "page 25 begins":
      merger.reset();
      merger.add(_withEndOfChunk([('page', 1000), ('25', 2900)], 5000));

      // Chunk 2 begins with "begins" at 50 ms. "begins" is not an echo of
      // "25" (unlike "five" or "twenty"), so it must NOT be treated as a cut
      // fragment.
      final res2 = merger.add(
        _withEndOfChunk([
          ('begins', 50),
          ('with', 800),
          ('chapter', 1400),
          ('one', 2200),
        ], 5000),
      );
      expect(res2.confirmed, 'page 25');
      expect(res2.unconfirmed, 'begins with chapter one');
    });

    test(
      'DoesNotDropWordsSharingSubstringOrEndingWithUnrelatedBoundaryWord',
      () {
        final merger = TimestampTextMerger(overlapRatio: 0.4);

        // Chunk 1 (0-5000): ends with "weather" at 2900 ms (just before chunk
        // 2's 3000 ms boundary).
        merger.add(_withEndOfChunk([('the', 1000), ('weather', 2900)], 5000));

        // Chunk 2 (3000-8000): starts with "the" at 50 ms (3050 ms absolute).
        // While "weather" and "the" both end in 'e' or share the trigram "the",
        // "the" is a valid word and not a boundary cut fragment of "weather".
        final res = merger.add(
          _withEndOfChunk([
            ('the', 50),
            ('sky', 800),
            ('is', 1400),
            ('clear', 2000),
          ], 5000),
        );
        expect(res.confirmed, 'the weather');
        expect(res.unconfirmed, 'the sky is clear');
      },
    );

    test('HyphenatedWordDoesNotDropSubstringsNotPrecededByDelimiter', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000): decodes "re-create" and "well-planned".
      merger.add(
        _withEndOfChunk([
          ('we', 500),
          ('re-create', 2000),
          ('well-planned', 3500),
        ], 5000),
      );

      // Chunk 2 (3000-8000): hears "well-planned" (3500), followed by valid
      // words "ed" and "ate". Because neither follows a delimiter in the
      // preceding word, neither is dropped.
      final res = merger.add(
        _withEndOfChunk([
          ('well-planned', 500),
          ('ed', 1200),
          ('ate', 1800),
          ('lunch', 2500),
        ], 5000),
      );
      expect(res.confirmed, 'we re-create');
      expect(res.unconfirmed, 'well-planned ed ate lunch');
    });

    test('HyphenatedSuffixEchoRespectsProximityGap', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Chunk 1 (0-5000): decodes "twenty-five" at 3400 ms.
      merger.add(
        _withEndOfChunk([('page', 1000), ('twenty-five', 3400)], 5000),
      );

      // Chunk 2 (3000-8000, overlap_len=2000, tol.match_late=1000 ms):
      // "five" appears at 2500 ms (5500 ms absolute), well after the overlap
      // and past tol.match_late from 3400 ms (|5500 - 3400| = 2100 > 1000).
      // It represents a genuine new sentence ("Five people arrived") and must
      // NOT be dropped.
      final res = merger.add(
        _withEndOfChunk([
          ('twenty-five', 400),
          ('five', 2500),
          ('people', 3100),
          ('arrived', 3700),
        ], 5000),
      );
      expect(res.confirmed, 'page');
      expect(res.unconfirmed, 'twenty-five five people arrived');
    });

    test(
      'DropsShortUnpairedTailWordAtEndOfPreviousChunkWindowInMilliseconds',
      () {
        final merger = TimestampTextMerger(overlapRatio: 0.4);

        // Chunk 1 (0-5000 ms): has a short 2-char truncated word "th" at 4950
        // ms, right at the end of the 5000 ms window (within 5000 -
        // tol.substitution).
        merger.add(
          _withEndOfChunk([
            ('start', 1000),
            ('reading', 3200),
            ('now', 4200),
            ('th', 4950),
          ], 5000),
        );

        // Chunk 2 (3000-8000 ms, chunk_start_ms=3000): hears "reading" (200),
        // "now" (1200), and continues with "complete" at 2500 (5500 ms
        // absolute), leaving "th" at 4950 unpaired. Because "th" is at the
        // end of chunk 1's window, it is dropped as an unconfirmed prev tail.
        final res2 = merger.add(
          _withEndOfChunk([
            ('reading', 200),
            ('now', 1200),
            ('complete', 2500),
          ], 5000),
        );
        expect(res2.confirmed, 'start');
        expect(res2.unconfirmed, 'reading now complete');
      },
    );

    test('ChineseWindowsWithoutSpacesAreNotDuplicated', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // Live Qwen3-ASR output for 5 s windows with a 2 s overlap: each window
      // repeats the tail of the previous one, and Chinese has no spaces
      // between words.
      final text = _mergeWindows(merger, [
        '你好吗？今天是晚上吃什么？北京有什么好玩的？',
        '北京有什么好玩的？这个秋天，是不是还可以？',
        '是不是还可以找个地方玩？',
        '这个中文的重复，为什么会中文会有重复呢？',
        '中文会有重复的。',
      ]);

      // The last window re-hears the previous window's tail ("中文会有重复呢？")
      // as "中文会有重复的。"; after the pivot the current window wins.
      expect(
        text,
        '你好吗？今天是晚上吃什么？北京有什么好玩的？这个秋天，'
        '是不是还可以找个地方玩？这个中文的重复，为什么会中文会有重复的。',
      );
    });

    test('ChineseWindowEndingMidSentenceIsMerged', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // The first window ends mid-sentence, so the model closes it with a
      // period that the next window does not have.
      final text = _mergeWindows(merger, [
        '你可以说中文吗？好像中文的。',
        '好像中文的质量还不错，可以做到实时吗？',
        '可以做到实时吗？可以的。',
      ]);

      expect(text, '你可以说中文吗？好像中文的质量还不错，可以做到实时吗？可以的。');
    });

    test('MixedChineseAndLatinKeepsWordSpacing', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      final result = merger.add(
        _words(['欢迎体验', 'Light', 'RT', 'Omni', '语音合成演示。']),
      );

      expect(result.unconfirmed, '欢迎体验 Light RT Omni 语音合成演示。');
    });

    test('TimestampedChineseSentenceWordIsNotDuplicated', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // A detokenizer that does not split CJK text emits each window as one
      // word carrying only its onset timestamp, plus the end of the chunk.
      final res1 = merger.add(_withEndOfChunk([('你好吗？北京有什么好玩的？', 200)], 5000));
      final res2 = merger.add(
        _withEndOfChunk([('北京有什么好玩的？这个秋天还可以。', 100)], 5000),
      );
      final flushed = _flush(merger);

      expect(
        res1.confirmed + res2.confirmed + flushed.confirmed,
        '你好吗？北京有什么好玩的？这个秋天还可以。',
      );
    });

    test('ChineseCharactersWithTimestampsMergeByTime', () {
      final merger = TimestampTextMerger(overlapRatio: 0.4);

      // One word per character, as emitted by `TokenizerDetokenizer` for a
      // timestamped decoder. The second window starts at 3000 (= 5000 * 0.6),
      // so "北京好玩" (3200..3800) is heard by both windows.
      final res1 = merger.add(
        _withEndOfChunk([
          ('你', 200),
          ('好', 1000),
          ('吗？', 2000),
          ('北', 3200),
          ('京', 3400),
          ('好', 3600),
          ('玩', 3800),
        ], 5000),
      );
      final res2 = merger.add(
        _withEndOfChunk([
          ('北', 200),
          ('京', 400),
          ('好', 600),
          ('玩', 800),
          ('的。', 1000),
          ('秋', 2500),
          ('天', 2700),
        ], 5000),
      );
      final flushed = _flush(merger);

      expect(res2.confirmed, '你好吗？');
      expect(
        res1.confirmed + res2.confirmed + flushed.confirmed,
        '你好吗？北京好玩的。秋天',
      );
    });

    test('WarmStartPrefixesAreReplacedByFirstFullWindow', () {
      final merger = TimestampTextMerger(overlapRatio: 0.75);

      // Warm-start 1 (0..1250ms, `is_warm_start = true`)
      final ws1 = merger.add(
        _withEndOfChunk(
          [('hello', 300), ('wor', 900)],
          5000,
          isWarmStart: true,
        ),
      );
      expect(ws1.confirmed, '');
      expect(ws1.unconfirmed, 'hello wor');

      // Warm-start 2 (0..2500ms, `is_warm_start = true`) corrects "wor" to
      // "world" without advancing stream_timestamp_offset_ms_.
      final ws2 = merger.add(
        _withEndOfChunk(
          [('hello', 300), ('world', 900), ('this', 1800)],
          5000,
          isWarmStart: true,
        ),
      );
      expect(ws2.confirmed, '');
      expect(ws2.unconfirmed, 'hello world this');

      // Warm-start 3 (empty partial window with `is_warm_start = true`)
      // preserves `prev_words_` so a transient decoder collapse on a longer
      // prefix does not blank out the displayed partial transcript before the
      // first full window.
      final ws3 = merger.add(_withEndOfChunk([], 5000, isWarmStart: true));
      expect(ws3.confirmed, '');
      expect(ws3.unconfirmed, 'hello world this');

      // First full window (0..5000ms, `is_warm_start = false`) replaces the
      // warm-start hypothesis and advances stream_timestamp_offset_ms_ to
      // 1250.
      final full1 = merger.add(
        _withEndOfChunk([
          ('hello', 300),
          ('world', 900),
          ('this', 1800),
          ('is', 2600),
          ('parakeet', 3500),
        ], 5000),
      );
      expect(full1.confirmed, '');
      expect(full1.unconfirmed, 'hello world this is parakeet');

      // Second full window (1250..6250ms, `is_warm_start = false`) confirms
      // words before 1250ms ("hello world") plus stabilized overlap words
      // before `pivot - tol.substitution` ("this is") and updates the
      // unconfirmed tail.
      final full2 = merger.add(
        _withEndOfChunk([
          ('this', 550),
          ('is', 1350),
          ('parakeet', 2250),
          ('streaming', 4100),
        ], 5000),
      );
      expect(full2.confirmed, 'hello world this is');
      expect(full2.unconfirmed, 'parakeet streaming');
    });

    test('FirstFullWindowWithTrimmedSilenceConfirmsWordsOnNextWindow', () {
      final merger = TimestampTextMerger(overlapRatio: 0.75);

      // First full window (0..5000ms) had trailing silence trimmed (e.g.
      // DecodeRange{0.0, 0.6}) so words only appear in the first 1500ms, with
      // `is_warm_start = false`.
      final win1 = merger.add(
        _withEndOfChunk([('call', 300), ('mom', 800)], 5000),
      );
      expect(win1.confirmed, '');
      expect(win1.unconfirmed, 'call mom');

      // Next full window (1250..6250ms) contains new speech after the pause
      // at 3500ms relative (4750ms absolute). "call mom" must be confirmed,
      // not replaced.
      final win2 = merger.add(
        _withEndOfChunk([('right', 3500), ('now', 4000)], 5000),
      );
      expect(win2.confirmed, 'call mom');
      expect(win2.unconfirmed, 'right now');
    });

    test('ConsecutiveSilentChunksFinalizePreviousWordsDuringLiveSilence', () {
      final merger = TimestampTextMerger(overlapRatio: 0.75);

      // Full window (0..5000ms) with speech ending at 2100ms.
      final win1 = merger.add(
        _withEndOfChunk([
          ('finalize', 800),
          ('the', 1400),
          ('transcripts', 2100),
        ], 5000),
      );
      expect(win1.confirmed, '');
      expect(win1.unconfirmed, 'finalize the transcripts');

      // First silent follow-up window (1250..6250ms) retains unconfirmed
      // words in case of a transient empty decode while advancing the stream
      // offset to 2500ms.
      final silent1 = merger.add(_withEndOfChunk([], 5000));
      expect(silent1.confirmed, '');
      expect(silent1.unconfirmed, 'finalize the transcripts');

      // Second consecutive silent window (2500..7500ms) starts after the last
      // spoken word's timestamp (2100ms < 2500ms) and immediately finalizes
      // the pending words without waiting for the speaker to talk again or
      // stop the stream.
      final silent2 = merger.add(_words([]));
      expect(silent2.confirmed, 'finalize the transcripts');
      expect(silent2.unconfirmed, '');

      // Subsequent silent windows emit no duplicate confirmed or interim
      // text.
      final silent3 = merger.add(_words([]));
      expect(silent3.confirmed, '');
      expect(silent3.unconfirmed, '');

      // When speech resumes after the pause (e.g. at 3750..8750ms) and spread
      // goes across two windows, a single gated silent follow-up chunk
      // (`PushWords({})`) immediately finalizes the remaining unconfirmed
      // words without waiting for a second silent chunk.
      final resume1 = merger.add(
        _withEndOfChunk([('speaking', 1000), ('again', 2000)], 5000),
      );
      expect(resume1.confirmed, '');
      expect(resume1.unconfirmed, 'speaking again');

      final gatedSilent = merger.add(_words([]));
      expect(gatedSilent.confirmed, 'speaking again');
      expect(gatedSilent.unconfirmed, '');
    });
  });
}
