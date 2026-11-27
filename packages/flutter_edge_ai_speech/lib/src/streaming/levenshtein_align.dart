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
// omni/speech2text/levenshtein_align.{h,cc}) to Dart for
// flutter_edge_ai_speech.

/// Word-sequence alignment helpers of the streaming text mergers.
///
/// String lengths and character edit distances are measured in UTF-8 bytes,
/// as in the C++ original (`std::string::size()`): they decide whether two
/// words are "close enough", so counting UTF-16 code units instead would
/// change which words match.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'text_utils.dart';

/// `(prevIndex, currIndex)`: a word of the previous chunk paired with a word
/// of the current one.
typedef WordIndexPair = (int, int);

/// The edit decision code for string sequence alignment.
enum AlignCode { insertion, deletion, substitution, correct }

/// Computes the Levenshtein sequence alignment between [refTokens] and
/// [hypTokens]. Returns the optimal alignment decision sequence.
List<AlignCode> alignTokens(List<String> refTokens, List<String> hypTokens) {
  final rLen = refTokens.length;
  final hLen = hypTokens.length;

  if (rLen == 0 && hLen == 0) {
    return const [];
  }

  // Costs: ins = 1, del = 1, match = 0, sub = 2
  final dp = List.generate(rLen + 1, (_) => List<int>.filled(hLen + 1, 0));
  final backptr = List.generate(
    rLen + 1,
    (_) => List<AlignCode>.filled(hLen + 1, AlignCode.deletion),
  );

  for (var i = 1; i <= rLen; ++i) {
    dp[i][0] = i;
    backptr[i][0] = AlignCode.deletion;
  }
  for (var j = 1; j <= hLen; ++j) {
    dp[0][j] = j;
    backptr[0][j] = AlignCode.insertion;
  }

  for (var i = 1; i <= rLen; ++i) {
    for (var j = 1; j <= hLen; ++j) {
      final delCost = dp[i - 1][j] + 1;
      final insCost = dp[i][j - 1] + 1;
      final isMatch = closeEnoughStr(refTokens[i - 1], hypTokens[j - 1]);
      final subCost = dp[i - 1][j - 1] + (isMatch ? 0 : 2);

      var minCost = subCost;
      var code = isMatch ? AlignCode.correct : AlignCode.substitution;

      if (insCost < minCost) {
        minCost = insCost;
        code = AlignCode.insertion;
      }
      if (delCost < minCost) {
        minCost = delCost;
        code = AlignCode.deletion;
      }

      dp[i][j] = minCost;
      backptr[i][j] = code;
    }
  }

  final alignment = <AlignCode>[];
  var i = rLen;
  var j = hLen;
  while (i > 0 || j > 0) {
    final code = backptr[i][j];
    alignment.add(code);
    if (code == AlignCode.insertion) {
      --j;
    } else if (code == AlignCode.deletion) {
      --i;
    } else {
      --i;
      --j;
    }
  }

  return alignment.reversed.toList();
}

/// Levenshtein distance between two byte sequences.
int levenshteinDistanceUtf8(List<int> s1, List<int> s2) {
  final len1 = s1.length;
  final len2 = s2.length;
  var prev = List<int>.generate(len2 + 1, (j) => j);
  var curr = List<int>.filled(len2 + 1, 0);
  for (var i = 1; i <= len1; ++i) {
    curr[0] = i;
    for (var j = 1; j <= len2; ++j) {
      final deletionCost = prev[j] + 1;
      final insertionCost = curr[j - 1] + 1;
      final matchOrSubCost = prev[j - 1] + (s1[i - 1] == s2[j - 1] ? 0 : 1);
      curr[j] = math.min(deletionCost, math.min(insertionCost, matchOrSubCost));
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[len2];
}

/// Computes the Levenshtein edit distance between two strings, over their
/// UTF-8 bytes.
int computeLevenshteinDistanceStr(String s1, String s2) =>
    levenshteinDistanceUtf8(utf8.encode(s1), utf8.encode(s2));

/// Computes the word-level Levenshtein edit distance between two word
/// sequences.
int computeLevenshteinDistanceWords(List<String> words1, List<String> words2) {
  final len1 = words1.length;
  final len2 = words2.length;
  final dp = List.generate(len1 + 1, (_) => List<int>.filled(len2 + 1, 0));

  for (var i = 0; i <= len1; ++i) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= len2; ++j) {
    dp[0][j] = j;
  }

  for (var i = 1; i <= len1; ++i) {
    for (var j = 1; j <= len2; ++j) {
      final deletionCost = dp[i - 1][j] + 1;
      final insertionCost = dp[i][j - 1] + 1;
      final matchOrSubCost =
          dp[i - 1][j - 1] +
          (closeEnoughStr(words1[i - 1], words2[j - 1]) ? 0 : 1);
      dp[i][j] = math.min(
        deletionCost,
        math.min(insertionCost, matchOrSubCost),
      );
    }
  }
  return dp[len1][len2];
}

/// Byte-level [canonicalizeStr].
Uint8List canonicalizeUtf8(List<int> word) {
  // absl::AsciiStrToLower: only A-Z change.
  final lower = Uint8List.fromList([
    for (final b in word) (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b,
  ]);
  final result = BytesBuilder(copy: false);
  var pos = 0;
  while (pos < lower.length) {
    final start = pos;
    final (cp, next) = decodeUtf8CodePoint(lower, pos);
    pos = next;
    if (isPunctuation(cp)) continue;
    result.add(Uint8List.sublistView(lower, start, pos));
  }
  return result.takeBytes();
}

/// Lowercases a word (ASCII only) and strips punctuation (ASCII and common
/// Unicode punctuation such as CJK and fullwidth marks).
String canonicalizeStr(String word) =>
    utf8.decode(canonicalizeUtf8(utf8.encode(word)), allowMalformed: true);

/// Lowercases each word and strips punctuation.
List<String> canonicalizeWords(List<String> words) => [
  for (final word in words) canonicalizeStr(word),
];

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; ++i) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Byte-level [closeEnoughCanonical].
bool closeEnoughCanonicalUtf8(List<int> c1, List<int> c2) {
  final minLen = math.min(c1.length, c2.length);
  if (minLen <= 3) {
    return _bytesEqual(c1, c2);
  }
  return levenshteinDistanceUtf8(c1, c2) <= 1;
}

/// True if two already-canonicalized strings match exactly (when the shorter
/// has a UTF-8 length <= 3) or have a byte Levenshtein distance <= 1.
bool closeEnoughCanonical(String c1, String c2) =>
    closeEnoughCanonicalUtf8(utf8.encode(c1), utf8.encode(c2));

/// True if two strings are close enough after canonicalization.
bool closeEnoughStr(String s1, String s2) => closeEnoughCanonicalUtf8(
  canonicalizeUtf8(utf8.encode(s1)),
  canonicalizeUtf8(utf8.encode(s2)),
);

/// True if two word lists have equal length and corresponding words are close
/// enough.
bool closeEnoughWords(List<String> l1, List<String> l2) {
  if (l1.length != l2.length) return false;
  for (var i = 0; i < l1.length; ++i) {
    if (!closeEnoughStr(l1[i], l2[i])) {
      return false;
    }
  }
  return true;
}

/// Finds the max overlapping suffix of [prevWords] and prefix of [currWords]
/// within [searchWindow] using [closeEnoughWords], and returns [currWords]
/// with the overlapping prefix removed.
List<String> dedupWords(
  List<String> prevWords,
  List<String> currWords, {
  int searchWindow = 2,
}) {
  final maxSearch = math.min(
    searchWindow,
    math.min(prevWords.length, currWords.length),
  );
  for (var i = maxSearch; i >= 1; --i) {
    final prevTail = prevWords.sublist(prevWords.length - i);
    final currHead = currWords.sublist(0, i);
    if (closeEnoughWords(prevTail, currHead)) {
      return currWords.sublist(i);
    }
  }
  return List.of(currWords);
}

// Extracts the longest contiguous `correct` run (preferring later runs of
// length >= 2 on ties) and all individual `correct` index pairs from the
// Levenshtein alignment of `prevWords[minPrev..]` and
// `currWords[0..maxCurr)`.
void _collectAlignedMatches(
  List<String> prevWords,
  int minPrev,
  List<String> currWords,
  int maxCurr,
  List<WordIndexPair> bestRun,
  List<WordIndexPair> allMatches,
) {
  final alignCodes = alignTokens(
    prevWords.sublist(minPrev),
    currWords.sublist(0, maxCurr),
  );
  final curRun = <WordIndexPair>[];
  var rIdx = 0;
  var hIdx = 0;
  for (final code in alignCodes) {
    if (code == AlignCode.correct) {
      allMatches.add((minPrev + rIdx, hIdx));
      curRun.add((minPrev + rIdx, hIdx));
      if (curRun.length > bestRun.length ||
          (curRun.length == bestRun.length && curRun.length >= 2)) {
        bestRun
          ..clear()
          ..addAll(curRun);
      }
    } else {
      curRun.clear();
    }
    if (code == AlignCode.deletion ||
        code == AlignCode.substitution ||
        code == AlignCode.correct) {
      ++rIdx;
    }
    if (code == AlignCode.insertion ||
        code == AlignCode.substitution ||
        code == AlignCode.correct) {
      ++hIdx;
    }
  }
}

// Fallback when the global Levenshtein alignment (`alignTokens`) did not find
// a contiguous match run of length >= 2: because a substitution has the same
// cost as an insertion + deletion (cost 2 = 1 + 1), a non-overlapping prefix
// in `prevWords` and suffix in `currWords` of similar length can cause the
// global DP to pair non-overlapping words as substitutions and break up a
// genuine >= 2-word overlap run at the seam. Scans directly for the longest
// contiguous `closeEnoughStr` run of length >= 2 near the chunk boundary
// (starting within the first 4 words of `currWords` or ending within the last
// 2 words of `prevWords`), preferring later runs in `prevWords` on ties.
void _findDirectSeamMatchRun(
  List<String> prevWords,
  int minPrev,
  List<String> currWords,
  int maxCurr,
  List<WordIndexPair> bestRun,
) {
  final nPrev = prevWords.length;
  for (var r = minPrev; r < nPrev; ++r) {
    for (var h = 0; h < maxCurr; ++h) {
      var len = 0;
      while (r + len < nPrev &&
          h + len < maxCurr &&
          closeEnoughStr(prevWords[r + len], currWords[h + len])) {
        ++len;
      }
      if (len >= 2 &&
          (h <= 3 || r + len + 2 >= nPrev) &&
          len >= bestRun.length) {
        bestRun.clear();
        for (var k = 0; k < len; ++k) {
          bestRun.add((r + k, h + k));
        }
      }
    }
  }
}

// Finds a pair of aligned matches separated by at most a small gap near the
// chunk boundary where at least one word is a content word (>= 6 chars).
void _findGappedSeamMatchPair(
  List<String> prevWords,
  List<WordIndexPair> allMatches,
  List<WordIndexPair> bestRun,
) {
  final nPrev = prevWords.length;
  for (var m = 0; m + 1 < allMatches.length; ++m) {
    final (p0, c0) = allMatches[m];
    final (p1, c1) = allMatches[m + 1];
    if (p1 > p0 &&
        c1 > c0 &&
        (p1 - p0) + (c1 - c0) <= 5 &&
        (c0 <= 2 || p1 + 2 >= nPrev) &&
        math.max(
              canonicalizeUtf8(utf8.encode(prevWords[p0])).length,
              canonicalizeUtf8(utf8.encode(prevWords[p1])).length,
            ) >=
            6) {
      bestRun
        ..clear()
        ..addAll([allMatches[m], allMatches[m + 1]]);
    }
  }
}

bool _isValidSingleWordSeamMatch(
  List<WordIndexPair> bestRun,
  int nPrev,
  List<String> currWords,
) {
  if (bestRun.length != 1) return false;
  final (p, c) = bestRun[0];
  return (p + 1 == nPrev && c == 0) ||
      (p + 3 >= nPrev &&
          c <= 1 &&
          canonicalizeUtf8(utf8.encode(currWords[c])).length >= 5);
}

/// Finds the best "seam run" in the overlap region between
/// `prevWords[minPrev..]` and `currWords[0..maxCurr)`, returning
/// `(prevIndex, currIndex)` word index pairs, or an empty list if no valid
/// seam match exists.
///
/// A "seam run" is a contiguous sequence of matching words ([closeEnoughStr])
/// at the boundary ("seam") where two consecutive overlapping ASR chunks are
/// stitched together. Stitching at a multi-word contiguous run avoids dropping
/// words when an isolated function word (e.g., "the") happens to match
/// earlier in `prevWords`:
///
/// ```text
///   prev_words: ["read", "the", "book", "on", "the", "table", "today"]
///                          |                    |       |        |
///   curr_words:          ["the",              "the", "table", "today", "now"]
///                          ^                    ^^^^^^^^^^^^^^^^^^^^^
///              isolated 1-word match            seam run (length 3)
/// ```
///
/// The best seam run is selected in three steps:
///   1. Global Levenshtein alignment: runs [alignTokens] on
///      `prevWords[minPrev..]` and `currWords[0..maxCurr)` and extracts the
///      longest contiguous run of [AlignCode.correct] matches (preferring
///      later runs in `prevWords` on ties of length >= 2).
///   2. Fallback boundary scan (when step 1 finds no run of length >= 2):
///      because substitution cost equals insertion + deletion cost
///      (2 = 1 + 1) in [alignTokens], non-overlapping prefixes/suffixes of
///      similar length can pair as substitutions and break up a genuine seam
///      overlap. Scans directly for the longest contiguous [closeEnoughStr]
///      run of length >= 2 near the boundary (`currIdx <= 3` or within the
///      last 2 words of `prevWords`), and if still < 2, looks for a pair of
///      aligned matches separated by a small gap near the boundary where at
///      least one word is a content word (>= 6 chars).
///   3. Single-word boundary validation: a 1-word match is accepted only if it
///      sits at the chunk boundary (the last word of `prevWords` and first
///      word of `currWords`, or a >= 5-char word within the last 3 words of
///      `prevWords` and first 2 words of `currWords`).
List<WordIndexPair> findBestSeamMatchRun(
  List<String> prevWords,
  int minPrev,
  List<String> currWords,
  int maxCurr,
) {
  final bestRun = <WordIndexPair>[];
  final allMatches = <WordIndexPair>[];
  _collectAlignedMatches(
    prevWords,
    minPrev,
    currWords,
    maxCurr,
    bestRun,
    allMatches,
  );
  if (bestRun.length < 2) {
    _findDirectSeamMatchRun(prevWords, minPrev, currWords, maxCurr, bestRun);
    if (bestRun.length < 2 && allMatches.length >= 2) {
      _findGappedSeamMatchPair(prevWords, allMatches, bestRun);
    }
  }
  if (bestRun.length >= 2 ||
      _isValidSingleWordSeamMatch(bestRun, prevWords.length, currWords)) {
    return bestRun;
  }
  return const [];
}
