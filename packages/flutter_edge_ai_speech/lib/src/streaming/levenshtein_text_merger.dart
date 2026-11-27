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
// omni/speech2text/levenshtein_text_merger.{h,cc}) to Dart for
// flutter_edge_ai_speech.

library;

import 'package:meta/meta.dart';

import 'detokenizer.dart';
import 'levenshtein_align.dart';
import 'text_merger.dart';
import 'text_utils.dart';

List<String> _extractChunkWords(List<DetokenizedWord> chunkWords) {
  final words = <String>[];
  for (final word in chunkWords) {
    if (word.isEndOfChunk) {
      break;
    }
    words.add(word.text);
  }
  return words;
}

/// Aligns and merges overlapping word streams from consecutive audio chunks
/// using Levenshtein distance sequence alignment.
final class LevenshteinTextMerger implements TextMerger {
  List<String> _unconfirmedWords = [];

  /// The cached unconfirmed words.
  @visibleForTesting
  List<String> get unconfirmedWordsForTesting =>
      List.unmodifiable(_unconfirmedWords);

  @override
  void reset() => _unconfirmedWords = [];

  @override
  MergeResult add(List<DetokenizedWord> chunkWords) {
    final currStrings = splitCjkCharacters(_extractChunkWords(chunkWords));
    if (currStrings.isEmpty) {
      return MergeResult('', joinWithCjkAwareSpacing(_unconfirmedWords));
    }

    if (_unconfirmedWords.isEmpty) {
      // Initial chunk: cache words as unconfirmed state.
      _unconfirmedWords = currStrings;
      return MergeResult('', joinWithCjkAwareSpacing(_unconfirmedWords));
    }

    final bestRun = findBestSeamMatchRun(
      _unconfirmedWords,
      0,
      currStrings,
      currStrings.length,
    );
    final firstMatchingRefIdx = bestRun.isEmpty
        ? _unconfirmedWords.length
        : bestRun.first.$1;
    final firstMatchingHypIdx = bestRun.isEmpty
        ? currStrings.length
        : bestRun.first.$2;

    final List<String> confirmed;
    if (firstMatchingRefIdx < _unconfirmedWords.length) {
      confirmed = _unconfirmedWords.sublist(0, firstMatchingRefIdx);
    } else {
      confirmed = _unconfirmedWords;
    }

    final List<String> newUnconfirmed;
    if (firstMatchingHypIdx < currStrings.length) {
      newUnconfirmed = currStrings.sublist(firstMatchingHypIdx);
    } else {
      newUnconfirmed = currStrings;
    }

    _unconfirmedWords = newUnconfirmed;
    return MergeResult(
      joinWithCjkAwareSpacing(confirmed),
      joinWithCjkAwareSpacing(_unconfirmedWords),
    );
  }

  @override
  MergeResult? flush() {
    if (_unconfirmedWords.isEmpty) return null;
    final result = MergeResult(joinWithCjkAwareSpacing(_unconfirmedWords), '');
    _unconfirmedWords = [];
    return result;
  }
}
