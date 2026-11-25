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
// omni/speech2text/timestamp_text_merger.{h,cc}) to Dart for
// flutter_edge_ai_speech.

/// The time-based text merger of the streaming speech-to-text pipeline.
///
/// Numeric notes for the port:
/// - The C++ constructor parameters `overlap_ratio` and `pivot_factor` are
///   `float`; they are rounded to float32 here ([_f32]) so that comparisons
///   such as `overlap_ratio >= 0.7f` and the float arithmetic of
///   `MergeByWordCount` give the same answers.
/// - Word lengths are UTF-8 byte lengths (`std::string::size()`), see
///   `levenshtein_align.dart`.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'detokenizer.dart';
import 'levenshtein_align.dart';
import 'text_merger.dart';
import 'text_utils.dart';

final Float32List _f32Scratch = Float32List(1);

/// [value] rounded to the nearest float32, as a C++ `float` holds it.
double _f32(double value) {
  _f32Scratch[0] = value;
  return _f32Scratch[0];
}

// Alignment costs. A substitution (same acoustic event, different words) is
// cheaper than an insertion plus a deletion but costlier than a match plus an
// indel, so a matching word is never traded for two substitutions. Pairing
// words whose timestamps disagree costs more than an indel pair, so it never
// happens.
const int _kMatchCost = 0;
const int _kIndelCost = 2;
const int _kSubstitutionCost = 3;
const int _kFarPairCost = 5;

enum _AlignOp { pair, prevOnly, currOnly }

// Timestamp tolerances of a merge, in timestamp units, scaled from the length
// of the overlap. Emission times of the same word differ between the two
// windows: near the end of its window the previous chunk tends to emit early
// (up to ~40% of the overlap has been observed), the current chunk rarely
// emits earlier than the previous one did.
final class _Tolerances {
  const _Tolerances({
    required this.substitution,
    required this.matchEarly,
    required this.matchLate,
  });

  // Max |dt| for two different words to be the same acoustic event.
  final double substitution;
  // Max (prev - curr) for close-enough words to be the same word.
  final double matchEarly;
  // Max (curr - prev) for close-enough words to be the same word.
  final double matchLate;
}

int _utf8Length(String s) => utf8.encode(s).length;

bool _isSorted(List<int> values) {
  for (var i = 1; i < values.length; ++i) {
    if (values[i] < values[i - 1]) return false;
  }
  return true;
}

bool _hasUsableTimestamps(List<String> words, List<int> timestamps) =>
    words.isNotEmpty &&
    timestamps.length == words.length &&
    _isSorted(timestamps);

bool _hasDistinctTimestamps(List<int> timestamps) =>
    timestamps.isNotEmpty && timestamps.last > timestamps.first;

bool _endsWith(List<int> text, List<int> suffix) {
  if (suffix.length > text.length) return false;
  final offset = text.length - suffix.length;
  for (var i = 0; i < suffix.length; ++i) {
    if (text[offset + i] != suffix[i]) return false;
  }
  return true;
}

int _asciiLower(int b) => (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b;

bool _endsWithIgnoreCase(List<int> text, List<int> suffix) {
  if (suffix.length > text.length) return false;
  final offset = text.length - suffix.length;
  for (var i = 0; i < suffix.length; ++i) {
    if (_asciiLower(text[offset + i]) != _asciiLower(suffix[i])) return false;
  }
  return true;
}

List<List<bool>> _buildCloseEnoughMatrix(
  List<Uint8List> canonPrev,
  List<Uint8List> canonCurr,
) => [
  for (var i = 0; i < canonPrev.length; ++i)
    [
      for (var j = 0; j < canonCurr.length; ++j)
        closeEnoughCanonicalUtf8(canonPrev[i], canonCurr[j]),
    ],
];

// Returns the shift that best maps the current chunk's timestamps onto the
// previous chunk's: the most frequent `curr - prev` difference among pairs of
// close-enough words (>= 2 canonical bytes) in the overlap region within
// `maxShift`, with ties broken towards 0. At least two supporting pairs are
// required, otherwise 0 is returned. This absorbs a systematic emission delay
// between the two windows.
int _estimateTimestampShift(
  List<Uint8List> canonPrev,
  List<int> prevTimestamps,
  List<Uint8List> canonCurr,
  List<int> currTimestamps,
  double streamOffsetMs,
  double prevEndMs,
  double maxShift,
) {
  // Ordered by shift, as the C++ std::map.
  final support = SplayTreeMap<int, int>();
  final minPrevTs = streamOffsetMs - 2.0 * maxShift;
  final maxCurrTs = prevEndMs + 2.0 * maxShift;
  for (var i = 0; i < canonPrev.length; ++i) {
    if (canonPrev[i].length < 2 || prevTimestamps[i] < minPrevTs) continue;
    for (var j = 0; j < canonCurr.length; ++j) {
      if (canonCurr[j].length < 2 || currTimestamps[j] > maxCurrTs) {
        continue;
      }
      final shift = currTimestamps[j] - prevTimestamps[i];
      if (shift.abs() > maxShift) continue;
      if (closeEnoughCanonicalUtf8(canonPrev[i], canonCurr[j])) {
        support[shift] = (support[shift] ?? 0) + 1;
      }
    }
  }
  var bestShift = 0;
  var bestSupport = 1;
  support.forEach((shift, count) {
    if (count > bestSupport ||
        (count == bestSupport && shift.abs() < bestShift.abs())) {
      bestShift = shift;
      bestSupport = count;
    }
  });
  return bestShift;
}

int _pairCost(
  bool isCloseEnough,
  double prevTime,
  double currTime,
  _Tolerances tol,
) {
  final dt = currTime - prevTime;
  if (isCloseEnough) {
    return (dt >= -tol.matchEarly && dt <= tol.matchLate)
        ? _kMatchCost
        : _kFarPairCost;
  }
  return dt.abs() <= tol.substitution ? _kSubstitutionCost : _kFarPairCost;
}

// Monotone alignment of the overlapping words of the two chunks: a Levenshtein
// alignment in which words may only be paired when their timestamps agree
// (see `_Tolerances`). Words that are far apart in time are never paired.
List<_AlignOp> _alignOverlap(
  List<List<bool>> closeMatrix,
  List<int> prevTimestamps,
  List<double> currTimes,
  _Tolerances tol,
) {
  final numPrev = prevTimestamps.length;
  final numCurr = currTimes.length;

  final cost = List.generate(
    numPrev + 1,
    (_) => List<int>.filled(numCurr + 1, 0),
  );
  for (var i = 0; i <= numPrev; ++i) {
    cost[i][0] = i * _kIndelCost;
  }
  for (var j = 0; j <= numCurr; ++j) {
    cost[0][j] = j * _kIndelCost;
  }
  for (var i = 1; i <= numPrev; ++i) {
    for (var j = 1; j <= numCurr; ++j) {
      final pairCost = _pairCost(
        closeMatrix[i - 1][j - 1],
        prevTimestamps[i - 1].toDouble(),
        currTimes[j - 1],
        tol,
      );
      cost[i][j] = math.min(
        cost[i - 1][j - 1] + pairCost,
        math.min(cost[i - 1][j] + _kIndelCost, cost[i][j - 1] + _kIndelCost),
      );
    }
  }

  final ops = <_AlignOp>[];
  var i = numPrev;
  var j = numCurr;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0) {
      final pairCost = _pairCost(
        closeMatrix[i - 1][j - 1],
        prevTimestamps[i - 1].toDouble(),
        currTimes[j - 1],
        tol,
      );
      if (cost[i][j] == cost[i - 1][j - 1] + pairCost) {
        ops.add(_AlignOp.pair);
        --i;
        --j;
        continue;
      }
    }
    final prevOnlyOk = i > 0 && cost[i][j] == cost[i - 1][j] + _kIndelCost;
    final currOnlyOk = j > 0 && cost[i][j] == cost[i][j - 1] + _kIndelCost;
    // When both are optimal, emit (walking backwards) the later word first so
    // that unmatched words of the two chunks interleave in time order.
    if (prevOnlyOk &&
        (!currOnlyOk || prevTimestamps[i - 1] >= currTimes[j - 1])) {
      ops.add(_AlignOp.prevOnly);
      --i;
    } else {
      ops.add(_AlignOp.currOnly);
      --j;
    }
  }
  return ops.reversed.toList();
}

bool _hasWordWithin(List<double> times, double time, double tolerance) {
  for (final t in times) {
    if ((t - time).abs() <= tolerance) return true;
  }
  return false;
}

// Marks which words of the previous overlap were paired with a close-enough
// word of the current chunk by `ops`.
List<bool> _findMatchedPrevOverlapWords(
  List<List<bool>> closeMatrix,
  List<_AlignOp> ops,
) {
  final prevOvMatched = List<bool>.filled(closeMatrix.length, false);
  var pi = 0;
  var cj = 0;
  for (final op in ops) {
    switch (op) {
      case _AlignOp.pair:
        if (closeMatrix[pi][cj]) {
          prevOvMatched[pi] = true;
        }
        ++pi;
        ++cj;
      case _AlignOp.prevOnly:
        ++pi;
      case _AlignOp.currOnly:
        ++cj;
    }
  }
  return prevOvMatched;
}

// A current-only word before the pivot is kept only where the previous chunk
// heard nothing: it is dropped when the previous chunk has an unpaired or
// substituted overlap word at about the same time. Words in `prev` that are
// already matched to their counterpart in `curr` only cover their own frame
// (`<= 1.0`), so short function words between matched words are not dropped.
bool _isCoveredByPrev(
  List<int> prevOvTs,
  List<bool> prevOvMatched,
  double time,
  _Tolerances tol,
) {
  for (var idx = 0; idx < prevOvTs.length; ++idx) {
    final limit = prevOvMatched[idx] ? 1.0 : tol.substitution;
    if ((prevOvTs[idx] - time).abs() <= limit) return true;
  }
  return false;
}

final Map<String, List<String>> _spokenNumberMap = () {
  const ones = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
  ];
  const teens = [
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
  ];
  const tens = [
    '',
    '',
    'twenty',
    'thirty',
    'forty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  ];
  final map = <String, List<String>>{
    '0': ['zero', 'oh'],
    '00': ['hundred'],
    '000': ['thousand'],
  };
  for (var d = 1; d <= 9; ++d) {
    map['$d'] = [ones[d]];
    map['0$d'] = ['oh${ones[d]}', ones[d]];
  }
  for (var t = 0; t <= 9; ++t) {
    map['${10 + t}'] = [teens[t]];
  }
  for (var t = 2; t <= 9; ++t) {
    map['${t}0'] = [tens[t]];
    for (var o = 1; o <= 9; ++o) {
      map['$t$o'] = ['${tens[t]}${ones[o]}', tens[t]];
    }
  }
  return map;
}();

// Returns true if `canonCurr` matches the spoken number or phonetic suffix of
// a numeric `canonPrev` token (e.g. "five" after "105" or "twenty" after
// "20").
bool _matchesSpokenNumberSuffix(Uint8List canonPrev, Uint8List canonCurr) {
  if (canonPrev.isEmpty ||
      canonPrev.last < 0x30 /* '0' */ ||
      canonPrev.last > 0x39 /* '9' */ ) {
    return false;
  }

  for (
    var suffixLen = 1;
    suffixLen <= math.min(3, canonPrev.length);
    ++suffixLen
  ) {
    final suffix = canonPrev.sublist(canonPrev.length - suffixLen);
    // Map keys are ASCII; a suffix that is not valid ASCII matches none.
    if (suffix.any((b) => b >= 0x80)) continue;
    final candidates = _spokenNumberMap[ascii.decode(suffix)];
    if (candidates == null) continue;
    for (final candString in candidates) {
      final cand = ascii.encode(candString);
      if (closeEnoughCanonicalUtf8(cand, canonCurr) ||
          _endsWith(cand, canonCurr)) {
        // `canon_curr == cand` is covered by both checks.
        return true;
      }
    }
  }
  return false;
}

// Returns true if `canonCurr` at the start of the current chunk looks like a
// truncated fragment, phonetic variant, or repeat of `canonPrev` that started
// just before the window boundary (e.g. a 1-2 byte fragment, a suffix or
// close-enough match, a spoken number suffix matching a numeric token, an
// overlap where a prefix of `canonCurr` of length >= 3 matches a suffix of
// `canonPrev`, or both words having length >= 4 with matching 2-byte suffix).
bool _isPartialOrMatchingBoundaryWord(
  Uint8List canonPrev,
  Uint8List canonCurr,
) {
  if (canonCurr.length <= 2) return true;
  if (_endsWith(canonPrev, canonCurr) ||
      closeEnoughCanonicalUtf8(canonPrev, canonCurr)) {
    return true;
  }
  if (_matchesSpokenNumberSuffix(canonPrev, canonCurr)) {
    return true;
  }
  for (
    var len = math.min(canonPrev.length, canonCurr.length);
    len >= 3;
    --len
  ) {
    if (_endsWith(canonPrev, Uint8List.sublistView(canonCurr, 0, len))) {
      return true;
    }
  }
  if (canonPrev.length >= 4 && canonCurr.length >= 4) {
    return canonPrev[canonPrev.length - 2] == canonCurr[canonCurr.length - 2] &&
        canonPrev[canonPrev.length - 1] == canonCurr[canonCurr.length - 1];
  }
  return false;
}

// Returns true when a current-only word at `time` starts the window while the
// previous chunk was mid-speech at the boundary (the tail of a word that
// started before `chunkStart` and was cut by the window start). Only previous
// words that started before `chunkStart` can cut the current word at the
// window start, and only when `canonCurrWord` looks like a partial
// suffix/fragment or repeat of that word, so genuinely new words missed by the
// previous chunk are preserved.
//
// Deviation from Omni (flutter_edge_ai_speech): Parakeet through this
// package's frontend emits the tail of a cut word 5-7 encoder frames into the
// window, past `tol.substitution` (about 4.7 frames), so "satisfaction" came
// out "satisfaction faction". Up to `tol.matchLate` the word is still dropped,
// but only when it is a strict suffix of the cut word; the looser rules keep
// their narrow band. Measured on LibriSpeech test-clean streams in the
// package README (a rule that also dropped a word whose prefix ends the cut
// word changed no word there, and could drop "therapist" after "another").
bool _isCutAtWindowStart(
  List<Uint8List> canonPrevWords,
  List<int> prevTimestamps,
  Uint8List canonCurrWord,
  double chunkStart,
  double time,
  _Tolerances tol,
) {
  if (time > chunkStart + tol.matchLate) return false;
  final narrow = time <= chunkStart + tol.substitution;
  for (var idx = 0; idx < prevTimestamps.length; ++idx) {
    final ts = prevTimestamps[idx];
    if (ts < chunkStart - tol.matchEarly ||
        ts >= chunkStart + tol.substitution ||
        ts >= time) {
      continue;
    }
    final prev = canonPrevWords[idx];
    if (narrow) {
      if (_isPartialOrMatchingBoundaryWord(prev, canonCurrWord)) return true;
      continue;
    }
    if (canonCurrWord.length < prev.length && _endsWith(prev, canonCurrWord)) {
      return true;
    }
  }
  return false;
}

// Appends `word` and a monotone (non-decreasing) timestamp to `mergedWords`
// and `mergedTimestamps`, skipping `word` when it duplicates the trailing
// component of an immediately preceding hyphenated or apostrophe-joined word
// (e.g. "five" after "twenty-five" or "s" after "it's") within
// `maxSuffixGap`.
void _appendMergedWord(
  List<String> mergedWords,
  List<int> mergedTimestamps,
  String word,
  int timestampMs, [
  double maxSuffixGap = -1.0,
]) {
  if (mergedWords.isNotEmpty) {
    final last = utf8.encode(mergedWords.last);
    final wordBytes = utf8.encode(word);
    if (last.length > wordBytes.length &&
        _endsWithIgnoreCase(last, wordBytes)) {
      final delim = last[last.length - wordBytes.length - 1];
      if (delim == 0x2D /* '-' */ || delim == 0x27 /* '\'' */ ) {
        if (maxSuffixGap < 0 ||
            (timestampMs - mergedTimestamps.last).abs() <= maxSuffixGap) {
          return;
        }
      }
    }
  }
  final monotoneTs = mergedTimestamps.isEmpty
      ? timestampMs
      : math.max(timestampMs, mergedTimestamps.last);
  mergedWords.add(word);
  mergedTimestamps.add(monotoneTs);
}

bool _startsWithDigit(String word) {
  if (word.isEmpty) return false;
  final c = word.codeUnitAt(0);
  return c >= 0x30 && c <= 0x39;
}

// Walks the overlap alignment `ops` around `pivot` and appends the surviving
// unconfirmed words and non-decreasing timestamps into `mergedWords` and
// `mergedTimestamps`:
// - Paired words (`pair`) come from `prev` before `pivot` and `curr` after it.
// - Unpaired `prev` words (`prevOnly`) are kept before `pivot`, or after
//   `pivot` when `curr` heard nothing at about the same time.
// - Unpaired `curr` words (`currOnly`) are kept after `pivot`, or before
//   `pivot` when `prev` neither covered that time nor cut a word at the window
//   start.
//
// Deviation from Omni (flutter_edge_ai_speech): the first [alreadyEmitted]
// `prevOvWords` were confirmed early by the previous merge and are already in
// the output. They take part in the alignment, so the current chunk's copies
// of them pair or count as covered instead of being merged again; the return
// value is how many of them lead [mergedWords], which the caller keeps as the
// confirmed prefix. A current-only word aligned before the last of them is
// dropped: it lies in text already confirmed. Omni drops them from `prevOvWords` instead, and the
// current chunk's copies come out a second time (`overlap_ratio >= 0.7`).
int _mergeAlignedOverlap({
  required List<Uint8List> canonPrevWords,
  required List<int> prevTimestamps,
  required List<String> prevOvWords,
  required List<int> prevOvTs,
  required List<String> currWords,
  required List<Uint8List> canonCurrWords,
  required List<int> currTimestamps,
  required List<double> currTimes,
  required List<List<bool>> closeMatrix,
  required List<_AlignOp> ops,
  required double chunkStart,
  required double pivot,
  required double prevEndMs,
  required _Tolerances tol,
  required List<String> mergedWords,
  required List<int> mergedTimestamps,
  int alreadyEmitted = 0,
}) {
  final prevOvMatched = _findMatchedPrevOverlapWords(closeMatrix, ops);
  // How many already-emitted previous words lead `mergedWords` so far.
  var emittedPrefix = 0;
  void appendPrev(int i) {
    final before = mergedWords.length;
    _appendMergedWord(
      mergedWords,
      mergedTimestamps,
      prevOvWords[i],
      prevOvTs[i],
      tol.matchLate,
    );
    if (i < alreadyEmitted &&
        mergedWords.length == before + 1 &&
        before == emittedPrefix) {
      ++emittedPrefix;
    }
  }

  var i = 0;
  var j = 0;
  for (final op in ops) {
    switch (op) {
      case _AlignOp.pair:
        // Before the pivot the previous chunk had more context, after it the
        // current one has.
        final preferPrevNumeric =
            !closeMatrix[i][j] &&
            prevOvTs[i] <= pivot + tol.substitution &&
            _startsWithDigit(prevOvWords[i]);
        if (prevOvTs[i] < pivot - 1e-4 || preferPrevNumeric) {
          appendPrev(i);
        } else {
          _appendMergedWord(
            mergedWords,
            mergedTimestamps,
            currWords[j],
            currTimestamps[j],
            tol.matchLate,
          );
        }
        ++i;
        ++j;
      case _AlignOp.prevOnly:
        final isUnconfirmedPrevTail =
            i + 1 == prevOvWords.length &&
            prevOvTs[i] >= prevEndMs - tol.substitution &&
            _utf8Length(prevOvWords[i]) <= 3 &&
            currTimes.isNotEmpty;
        if (prevOvTs[i] < pivot ||
            (!isUnconfirmedPrevTail &&
                !_hasWordWithin(
                  currTimes,
                  prevOvTs[i].toDouble(),
                  tol.substitution,
                ))) {
          appendPrev(i);
        }
        ++i;
      case _AlignOp.currOnly:
        if (i < alreadyEmitted) {
          // Deviation from Omni: a current-only word aligned before a previous
          // word that is already out lies in text already confirmed; keeping
          // it would put it after that text and repeat the confirmed words
          // that follow (a fragment cut at the window start, mostly).
        } else if (currTimes[j] >= pivot) {
          _appendMergedWord(
            mergedWords,
            mergedTimestamps,
            currWords[j],
            currTimestamps[j],
            tol.matchLate,
          );
        } else if (!_isCoveredByPrev(
              prevOvTs,
              prevOvMatched,
              currTimes[j],
              tol,
            ) &&
            !_isCutAtWindowStart(
              canonPrevWords,
              prevTimestamps,
              canonCurrWords[j],
              chunkStart,
              currTimes[j],
              tol,
            )) {
          _appendMergedWord(
            mergedWords,
            mergedTimestamps,
            currWords[j],
            // std::lround: half away from zero, as Dart's round().
            currTimes[j].round(),
            tol.matchLate,
          );
        }
        ++j;
    }
  }
  for (; j < currWords.length; ++j) {
    _appendMergedWord(
      mergedWords,
      mergedTimestamps,
      currWords[j],
      currTimestamps[j],
      tol.matchLate,
    );
  }
  return emittedPrefix;
}

List<Uint8List> _canonicalizeWordsUtf8(List<String> words) => [
  for (final word in words) canonicalizeUtf8(utf8.encode(word)),
];

/// Aligns and merges overlapping word streams from consecutive audio chunks.
///
/// When words carry timestamps (TDT / CTC decoders) the merge is time-based:
/// words of the previous chunk that lie before the current chunk are
/// confirmed; inside the overlap of the two windows the words are aligned by
/// text and time, the previous chunk's words are kept up to a pivot
/// ([pivotFactor] of the overlap, where they still had context on both sides)
/// and the current chunk's words are used after it. Without timestamps a
/// seam-run Levenshtein alignment on word counts is used instead.
/// It works better for live audio streaming than `LevenshteinTextMerger`.
///
/// Timestamps of a chunk are relative to its start; the merger tracks the
/// absolute stream offset itself, advancing it by
/// `chunkEnd * (1 - overlapRatio)` per (non-warm-start) chunk, where
/// `chunkEnd` is the end-of-chunk sentinel's timestamp when present.
final class TimestampTextMerger implements TextMerger {
  TimestampTextMerger({
    double overlapRatio = 0.5,
    this.searchWindow = 4,
    double pivotFactor = 0.6,
  }) : overlapRatio = _f32(overlapRatio),
       pivotFactor = _f32(pivotFactor);

  /// Fraction of a window shared with the next one (a C++ `float`).
  final double overlapRatio;

  /// Seam search slack of the word-count merge.
  final int searchWindow;

  /// Where in the overlap the current chunk starts to win (a C++ `float`).
  final double pivotFactor;

  List<String> _prevWords = [];
  List<int> _prevTimestamps = [];
  List<String> _lastConfirmedWords = [];
  // Absolute start of the current chunk (sum of the previous chunks' steps).
  // Kept as a double: the step is `endOfChunk * (1 - overlapRatio)`, which is
  // fractional in encoder frames.
  double _streamTimestampOffsetMs = 0.0;
  // Absolute end of the previous chunk's window (-1 if unknown).
  double _prevChunkEndMs = -1.0;
  // Duration of the most recent non-empty chunk, used to advance
  // `_streamTimestampOffsetMs` across silent chunks that carry no sentinel.
  int _lastChunkEndMs = 0;
  // Whether `_prevWords` currently holds a progressive warm-start prefix that
  // should be replaced rather than merged by the next chunk.
  bool _prevIsWarmStart = false;
  // Number of consecutive non-warm-start empty chunks observed since the last
  // chunk with spoken words.
  int _consecutiveEmptyChunks = 0;
  // Number of leading words in `_prevWords` that have already been emitted in
  // `confirmed` (while remaining in `_prevWords` for overlap alignment on the
  // next window).
  int _confirmedPrefixSize = 0;
  // Upper timestamp bound of words already finalized during a live silence
  // pause, used to avoid re-emitting pre-pause words that remain in the left
  // overlap prefix of a subsequent window.
  int _confirmedUntilMs = -1;

  /// The cached unconfirmed words.
  @visibleForTesting
  List<String> get unconfirmedWordsForTesting => List.unmodifiable(
    _prevWords.sublist(math.min(_confirmedPrefixSize, _prevWords.length)),
  );

  /// The absolute start of the next chunk in timestamp units.
  @visibleForTesting
  double get streamTimestampOffsetForTesting => _streamTimestampOffsetMs;

  /// Not in Omni: the timestamp of the first word not confirmed yet, in the
  /// merger's clock (the windows' timestamp unit, from the stream start);
  /// null when every word heard is confirmed; -1 when the unconfirmed words
  /// carry no usable timestamps (a word-count merge).
  int? get firstUnconfirmedTimestamp {
    final prefix = math.min(_confirmedPrefixSize, _prevWords.length);
    if (prefix >= _prevWords.length) return null;
    if (_prevTimestamps.length != _prevWords.length) return -1;
    return _prevTimestamps[prefix];
  }

  @override
  void reset() {
    _prevWords = [];
    _prevTimestamps = [];
    _lastConfirmedWords = [];
    _streamTimestampOffsetMs = 0.0;
    _prevChunkEndMs = -1.0;
    _lastChunkEndMs = 0;
    _prevIsWarmStart = false;
    _consecutiveEmptyChunks = 0;
    _confirmedPrefixSize = 0;
    _confirmedUntilMs = -1;
  }

  String _unconfirmedText() {
    final prefix = math.min(_confirmedPrefixSize, _prevWords.length);
    return prefix >= _prevWords.length
        ? ''
        : joinWithCjkAwareSpacing(_prevWords.sublist(prefix));
  }

  @override
  MergeResult add(List<DetokenizedWord> chunkWords) {
    final chunkStartMs = _streamTimestampOffsetMs.round();
    final currWords = <String>[];
    final currTimestamps = <int>[];
    int? maxChunkTimestampMs;
    var isWarmStartChunk = false;
    // Whether a word had to be split into several units below.
    var splitWord = false;
    for (final word in chunkWords) {
      if (word.isEndOfChunk) {
        isWarmStartChunk = word.isWarmStart;
        if (word.timestampMs != null) {
          maxChunkTimestampMs = word.timestampMs;
        }
        continue;
      }
      // Align CJK text character by character (see `splitCjkCharacters`).
      // `TokenizerDetokenizer` already emits one word per CJK character; this
      // only splits words from detokenizers that do not.
      final units = splitCjkCharacters([word.text]);
      splitWord |= units.length > 1;
      for (final unit in units) {
        final ts = word.timestampMs;
        if (ts != null) {
          final absTs = ts + chunkStartMs;
          if (_confirmedUntilMs >= 0 && absTs <= _confirmedUntilMs) {
            continue;
          }
          currTimestamps.add(absTs);
        }
        currWords.add(unit);
      }
    }
    // End of the chunk relative to its start; falls back to the last word's
    // timestamp (or the previous chunk's duration for a silent chunk) when the
    // decoder does not report the end of the chunk.
    final chunkEndMs =
        maxChunkTimestampMs ??
        (currTimestamps.isEmpty
            ? _lastChunkEndMs
            : currTimestamps.last - chunkStartMs);
    if (chunkEndMs > 0) {
      _lastChunkEndMs = chunkEndMs;
    }
    // A split word's timestamp is the onset of its first unit only; using it
    // for every unit would confirm the whole word as soon as its onset falls
    // before the next chunk, so such chunks are merged by word count instead.
    if (splitWord) currTimestamps.clear();

    if (currWords.isEmpty) {
      var confirmed = '';
      if (!isWarmStartChunk) {
        ++_consecutiveEmptyChunks;
        final isGatedFollowupSilence =
            maxChunkTimestampMs == null &&
            _lastChunkEndMs > 0 &&
            _prevChunkEndMs > _lastChunkEndMs.toDouble();
        if (_prevWords.isNotEmpty &&
            !_prevIsWarmStart &&
            ((_prevChunkEndMs >= 0.0 &&
                    _prevChunkEndMs <= _streamTimestampOffsetMs) ||
                _consecutiveEmptyChunks >= 2 ||
                isGatedFollowupSilence)) {
          if (_prevTimestamps.isNotEmpty) {
            // static_cast<int>: truncation toward zero.
            _confirmedUntilMs =
                _prevTimestamps.last +
                math.max(1, (0.08 * _lastChunkEndMs).truncate());
          }
          final prefix = math.min(_confirmedPrefixSize, _prevWords.length);
          confirmed = joinWithCjkAwareSpacing(_prevWords.sublist(prefix));
          _prevWords = [];
          _prevTimestamps = [];
          _confirmedPrefixSize = 0;
        }
        _updateStreamTimestampOffset(chunkEndMs);
      }
      return MergeResult(confirmed, _unconfirmedText());
    }
    _consecutiveEmptyChunks = 0;

    if (overlapRatio == 0.0) {
      return MergeResult(joinWithCjkAwareSpacing(currWords), '');
    }

    if (_prevWords.isEmpty || _prevIsWarmStart) {
      _prevWords = currWords;
      _prevTimestamps = currTimestamps;
      _prevIsWarmStart = isWarmStartChunk;
      _confirmedPrefixSize = 0;
      if (!isWarmStartChunk) {
        _prevChunkEndMs = _streamTimestampOffsetMs + chunkEndMs;
        _updateStreamTimestampOffset(chunkEndMs);
      }
      return MergeResult('', joinWithCjkAwareSpacing(_prevWords));
    }

    // Chunks whose words all share one timestamp carry no timing information
    // unless the decoder reports the end of the chunk.
    final currHasUsableTs = _hasUsableTimestamps(currWords, currTimestamps);
    final useTime =
        _prevChunkEndMs >= 0.0 &&
        _hasUsableTimestamps(_prevWords, _prevTimestamps) &&
        currHasUsableTs &&
        (maxChunkTimestampMs != null ||
            _hasDistinctTimestamps(_prevTimestamps) ||
            _hasDistinctTimestamps(currTimestamps));
    if (useTime) {
      _mergeByTime(currWords, currTimestamps);
    } else {
      // Omni logs the fallback to MergeByWordCount (first 5 times) when the
      // current chunk had usable timestamps.
      _mergeByWordCount(currWords, currTimestamps);
    }
    _prevChunkEndMs = _streamTimestampOffsetMs + chunkEndMs;
    _updateStreamTimestampOffset(chunkEndMs);

    return MergeResult(
      joinWithCjkAwareSpacing(_lastConfirmedWords),
      _unconfirmedText(),
    );
  }

  // Time-based merge of `currWords` (absolute `currTimestamps`, one per word)
  // into the previous chunk's unconfirmed words; updates `_prevWords`,
  // `_prevTimestamps` and `_lastConfirmedWords`.
  void _mergeByTime(List<String> currWords, List<int> currTimestamps) {
    if (_prevChunkEndMs <= _streamTimestampOffsetMs) {
      // The window that produced the previous words ends before this chunk
      // (e.g. an empty chunk in between): the previous words are final.
      final alreadyConfirmed = math.min(
        _confirmedPrefixSize,
        _prevWords.length,
      );
      _lastConfirmedWords = _prevWords.sublist(alreadyConfirmed);
      _confirmedPrefixSize = 0;
      _prevWords = List.of(currWords);
      _prevTimestamps = List.of(currTimestamps);
      return;
    }

    final overlapLen = _prevChunkEndMs - _streamTimestampOffsetMs;
    final tolScale = _lastChunkEndMs > 0
        ? math.min(overlapLen, 0.5 * _lastChunkEndMs.toDouble())
        : overlapLen;
    final tol = _Tolerances(
      substitution: math.max(1.0, 0.15 * tolScale),
      matchEarly: math.max(2.0, 0.25 * tolScale),
      matchLate: math.max(2.0, 0.5 * tolScale),
    );

    final canonPrevWords = _canonicalizeWordsUtf8(_prevWords);
    final canonCurrWords = _canonicalizeWordsUtf8(currWords);

    // Express the current chunk's word timestamps and both overlap window
    // bounds in the previous chunk's word clock by subtracting `shift`
    // (`curr - prev`).
    final shift = _estimateTimestampShift(
      canonPrevWords,
      _prevTimestamps,
      canonCurrWords,
      currTimestamps,
      _streamTimestampOffsetMs,
      _prevChunkEndMs,
      tol.matchEarly,
    );
    final chunkStart = _streamTimestampOffsetMs - shift;
    final prevEnd = _prevChunkEndMs - shift;
    final pivot = chunkStart + pivotFactor * (prevEnd - chunkStart);
    final currTimes = [
      for (final ts in currTimestamps) (ts - shift).toDouble(),
    ];

    // Previous words before the current chunk are final.
    var numConfirmed = 0;
    while (numConfirmed < _prevTimestamps.length &&
        _prevTimestamps[numConfirmed] < chunkStart) {
      ++numConfirmed;
    }
    final alreadyConfirmed = math.min(_confirmedPrefixSize, _prevWords.length);
    // Deviation from Omni: words confirmed early by the previous merge but
    // still inside this chunk stay in the overlap (see _mergeAlignedOverlap);
    // Omni moves numConfirmed past them (`std::max(num_confirmed,
    // already_confirmed)`).
    _lastConfirmedWords = numConfirmed > alreadyConfirmed
        ? _prevWords.sublist(alreadyConfirmed, numConfirmed)
        : <String>[];
    final alreadyEmitted = math.max(0, alreadyConfirmed - numConfirmed);
    _confirmedPrefixSize = 0;
    final prevOvWords = _prevWords.sublist(numConfirmed);
    final canonPrevOvWords = canonPrevWords.sublist(numConfirmed);
    final prevOvTs = _prevTimestamps.sublist(numConfirmed);

    // Current words well beyond the previous window are new; the margin lets
    // the last words of the previous window, emitted early, find their pair.
    var numOverlap = 0;
    while (numOverlap < currTimes.length &&
        currTimes[numOverlap] < prevEnd + tol.matchLate) {
      ++numOverlap;
    }

    final closeMatrix = _buildCloseEnoughMatrix(
      canonPrevOvWords,
      canonCurrWords.sublist(0, numOverlap),
    );
    final ops = _alignOverlap(
      closeMatrix,
      prevOvTs,
      currTimes.sublist(0, numOverlap),
      tol,
    );

    final mergedWords = <String>[];
    final mergedTimestamps = <int>[];
    final emittedPrefix = _mergeAlignedOverlap(
      canonPrevWords: canonPrevWords,
      prevTimestamps: _prevTimestamps,
      prevOvWords: prevOvWords,
      prevOvTs: prevOvTs,
      currWords: currWords,
      canonCurrWords: canonCurrWords,
      currTimestamps: currTimestamps,
      currTimes: currTimes,
      closeMatrix: closeMatrix,
      ops: ops,
      chunkStart: chunkStart,
      pivot: pivot,
      prevEndMs: _prevChunkEndMs,
      tol: tol,
      mergedWords: mergedWords,
      mergedTimestamps: mergedTimestamps,
      alreadyEmitted: alreadyEmitted,
    );

    _prevWords = mergedWords;
    _prevTimestamps = mergedTimestamps;
    _confirmedPrefixSize = emittedPrefix;
    if (overlapRatio >= _f32(0.7)) {
      final earlyConfirmLimit = pivot - tol.substitution;
      while (_confirmedPrefixSize < _prevTimestamps.length &&
          _prevTimestamps[_confirmedPrefixSize] < earlyConfirmLimit) {
        _lastConfirmedWords.add(_prevWords[_confirmedPrefixSize]);
        ++_confirmedPrefixSize;
      }
    }
  }

  // Merge by word counts and seam-run alignment, used when timestamps are
  // unavailable. Re-seeds `_prevTimestamps` when `currTimestamps` are usable.
  void _mergeByWordCount(List<String> currWords, List<int> currTimestamps) {
    if (_confirmedPrefixSize > 0) {
      final drop = math.min(_confirmedPrefixSize, _prevWords.length);
      _prevWords = _prevWords.sublist(drop);
      if (_prevTimestamps.length >= drop) {
        _prevTimestamps = _prevTimestamps.sublist(drop);
      } else {
        _prevTimestamps = [];
      }
      _confirmedPrefixSize = 0;
    }
    final currHasUsableTs = _hasUsableTimestamps(currWords, currTimestamps);
    if (_prevWords.isNotEmpty && currWords.isNotEmpty) {
      final nPrev = _prevWords.length;
      final nCurr = currWords.length;
      // `n_prev * (1.0f - overlap_ratio_)` and `n_curr * overlap_ratio_` are
      // float products in C++.
      final minPrev = nPrev > 8
          ? math.max(
              1,
              math.max(
                0,
                _f32(
                      _f32(nPrev.toDouble()) * _f32(1.0 - overlapRatio),
                    ).truncate() -
                    searchWindow -
                    2,
              ),
            )
          : 0;
      final maxCurr = math.min(
        nCurr,
        _f32(_f32(nCurr.toDouble()) * overlapRatio).ceil() + searchWindow + 4,
      );
      final bestRun = findBestSeamMatchRun(
        _prevWords,
        minPrev,
        currWords,
        maxCurr,
      );
      if (bestRun.isNotEmpty) {
        final (p0, c0) = bestRun.first;
        final (pPiv, cPiv) = bestRun[bestRun.length ~/ 2];
        final unconfirmedIdx = (p0 - c0).clamp(minPrev, p0);
        _lastConfirmedWords = _prevWords.sublist(0, unconfirmedIdx);
        final prefixLen = pPiv - unconfirmedIdx;
        final unconfirmedMerged = _prevWords.sublist(unconfirmedIdx, pPiv);
        if (nCurr - cPiv >= nPrev - pPiv) {
          unconfirmedMerged.addAll(currWords.sublist(cPiv));
        } else {
          unconfirmedMerged.addAll(_prevWords.sublist(pPiv));
        }
        _prevWords = unconfirmedMerged;
        _prevTimestamps = [];
        if (currHasUsableTs) {
          for (var k = 0; k < _prevWords.length; ++k) {
            final cIdx = (cPiv + k - prefixLen).clamp(0, nCurr - 1);
            _prevTimestamps.add(currTimestamps[cIdx]);
          }
        }
        return;
      }
    }

    _lastConfirmedWords = _prevWords;
    _prevWords = List.of(currWords);
    if (currHasUsableTs) {
      _prevTimestamps = List.of(currTimestamps);
    } else {
      _prevTimestamps = [];
    }
  }

  @override
  MergeResult? flush() {
    final prefix = math.min(_confirmedPrefixSize, _prevWords.length);
    final MergeResult? result = prefix < _prevWords.length
        ? MergeResult(joinWithCjkAwareSpacing(_prevWords.sublist(prefix)), '')
        : null;
    _prevWords = [];
    _prevTimestamps = [];
    _lastConfirmedWords = [];
    _confirmedPrefixSize = 0;
    _confirmedUntilMs = -1;
    _prevChunkEndMs = -1.0;
    _lastChunkEndMs = 0;
    return result;
  }

  // Advances the stream offset by the hop of a chunk ending at `chunkEndMs`
  // (relative to its start).
  void _updateStreamTimestampOffset(int chunkEndMs) {
    if (overlapRatio <= 0.0) return;
    // Kept fractional: with encoder-frame timestamps the step is not a whole
    // number of frames, and truncating it drifts by a frame every few chunks.
    if (chunkEndMs > 0) {
      _streamTimestampOffsetMs += chunkEndMs * (1.0 - overlapRatio);
    }
  }
}
