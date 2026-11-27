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
// omni/speech2text/ctc_decoder.cc, CtcDecoder::Decode) to Dart for
// flutter_edge_ai_speech; blank tokens can be dropped here (Omni leaves them
// to its detokenizer) and a NaN logit fails the window, as the batch
// decoder does.

/// Greedy CTC over one window's logits, keeping each emitted token's encoder
/// frame for the timestamp merger.
library;

import 'dart:typed_data';

import 'detokenizer.dart' show DecodedToken;

/// The tokens of one window: one [DecodedToken] per change of the per-frame
/// arg-max (repeats collapsed), with its frame relative to the first
/// reported frame, then the end-of-chunk sentinel carrying the window's frame
/// count from that same origin.
///
/// [validFraction] in (0, 1) decodes only the first
/// `round(validFraction * numFrames)` frames (a window whose tail is
/// padding); [startFraction] in (0, 1) still collapses repeats from frame 0
/// but reports nothing before `floor(startFraction * numFrames)` (a window
/// shifted back over audio already reported). Values outside (0, 1) mean the
/// whole window. [blankId] tokens are dropped when given.
List<DecodedToken> ctcWindowTokens(
  Float32List logits, {
  required int numFrames,
  required int vocabSize,
  double validFraction = 1,
  double startFraction = 0,
  int? blankId,
}) {
  if (vocabSize <= 0) {
    throw ArgumentError.value(vocabSize, 'vocabSize', 'must be positive');
  }
  if (numFrames == 0 || logits.isEmpty) return const [];
  if (logits.length < numFrames * vocabSize) {
    throw ArgumentError.value(
      logits.length,
      'logits.length',
      'shorter than numFrames * vocabSize (${numFrames * vocabSize})',
    );
  }
  var framesToDecode = numFrames;
  if (validFraction > 0 && validFraction < 1) {
    final valid = (validFraction * numFrames).round();
    framesToDecode = valid < numFrames ? valid : numFrames;
  }
  var firstReported = 0;
  if (startFraction > 0 && startFraction < 1) {
    firstReported = (startFraction * numFrames).floor();
  }
  final tokens = <DecodedToken>[];
  var previous = -1;
  for (var t = 0; t < framesToDecode; t++) {
    final base = t * vocabSize;
    var best = 0;
    var bestValue = logits[base];
    for (var v = 0; v < vocabSize; v++) {
      final value = logits[base + v];
      if (value.isNaN) {
        throw StateError(
          'STT CTC decode produced NaN logits at frame $t — the model backend '
          'returned invalid output; the window is not transcribed.',
        );
      }
      if (value > bestValue) {
        bestValue = value;
        best = v;
      }
    }
    if (best == previous) continue;
    previous = best;
    if (t < firstReported) continue;
    if (blankId != null && best == blankId) continue;
    tokens.add(DecodedToken(best, timestampMs: t - firstReported));
  }
  tokens.add(DecodedToken.endOfChunk(timestampMs: numFrames - firstReported));
  return tokens;
}

/// The `validFraction` [ctcWindowTokens] takes for a window whose first
/// [validSamples] are audio: whole mel frames of [hopLength] samples, out of
/// [melFrames]. Less than one hop of audio gives the smallest positive
/// fraction, so nothing is decoded: [ctcWindowTokens] reads 0 as "the whole
/// window", which would decode the zero padding.
double ctcValidFraction({
  required int validSamples,
  required int hopLength,
  required int melFrames,
}) {
  final frames = validSamples ~/ hopLength;
  if (frames <= 0) return double.minPositive;
  return frames >= melFrames ? 1 : frames / melFrames;
}
