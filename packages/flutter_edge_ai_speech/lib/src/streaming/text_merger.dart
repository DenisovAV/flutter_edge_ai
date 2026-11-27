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
// omni/speech2text/text_merger.h) to Dart for flutter_edge_ai_speech.

/// The text-merger contract of the streaming speech-to-text pipeline.
///
/// In LiteRT-LM Omni a merger is a pipeline stage that pulls word lists from
/// the detokenizer stage and pushes `TextOutput`s; here it is a plain
/// synchronous object: one [TextMerger.add] per decoded audio window.
library;

import 'detokenizer.dart';

/// What a merger reports after a window: [confirmed] is text newly confirmed
/// by this call (never repeated by a later call), [unconfirmed] is the
/// current tail, which a later window may still revise.
///
/// Mirrors Omni's `TextOutput` (`confirmed_text`, `unconfirmed_text`).
final class MergeResult {
  const MergeResult(this.confirmed, this.unconfirmed);

  final String confirmed;
  final String unconfirmed;

  @override
  bool operator ==(Object other) =>
      other is MergeResult &&
      other.confirmed == confirmed &&
      other.unconfirmed == unconfirmed;

  @override
  int get hashCode => Object.hash(confirmed, unconfirmed);

  @override
  String toString() =>
      'MergeResult(confirmed: "$confirmed", unconfirmed: "$unconfirmed")';
}

/// Aligns and merges overlapping word streams from consecutive audio windows.
abstract interface class TextMerger {
  /// Merges the words of the next window (its detokenizer output, end-of-chunk
  /// sentinel included when the decoder reports one).
  MergeResult add(List<DetokenizedWord> chunkWords);

  /// Confirms whatever is still unconfirmed at the end of a stream. Returns
  /// null when there is nothing left (the C++ stage pushes no output then).
  MergeResult? flush();

  /// Forgets all state, for a new stream.
  void reset();
}
