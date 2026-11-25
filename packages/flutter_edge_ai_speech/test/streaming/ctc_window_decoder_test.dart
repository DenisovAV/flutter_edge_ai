// Ported from LiteRT-LM v0.19.1 omni/speech2text/ctc_decoder_test.cc (same
// inputs and expectations), plus this port's own cases below the ported ones.
// Not ported: CreateInvalidVocabSizeFails / CreateValidVocabSizeSucceeds as
// such (there is no decoder object; an invalid vocabSize throws, checked
// below), DecodeEmptyEncoderOutputsReturnsEmpty becomes empty logits.
import 'dart:typed_data';

import 'package:flutter_edge_ai_speech/src/streaming/ctc_window_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ported', () {
    test('DecodeEmptyEncoderOutputsReturnsEmpty', () {
      expect(
        ctcWindowTokens(Float32List(0), numFrames: 0, vocabSize: 4),
        isEmpty,
      );
    });

    test('DecodeIncludesEndOfChunkToken', () {
      final tokens = ctcWindowTokens(
        Float32List.fromList([1, 0, 0, 1]),
        numFrames: 2,
        vocabSize: 2,
      );
      expect(tokens.length, greaterThanOrEqualTo(1));
      expect(tokens.last.isEndOfChunk, isTrue);
      expect(tokens.last.timestampMs, 2);
    });

    test('DecodeRangeValidFractionBoundsDecoding', () {
      const numFrames = 8;
      // Frame t emits token (t % 2), so every frame yields a new token.
      final logits = Float32List(numFrames * 2);
      for (var t = 0; t < numFrames; ++t) {
        logits[t * 2] = t.isEven ? 1 : 0;
        logits[t * 2 + 1] = t.isEven ? 0 : 1;
      }
      // 25% of the window is real audio: round(0.25 * 8) = 2 valid frames.
      var tokens = ctcWindowTokens(
        logits,
        numFrames: numFrames,
        vocabSize: 2,
        validFraction: 0.25,
      );
      const expectedFrames = 2;
      expect(tokens.length, expectedFrames + 1);
      expect(tokens[expectedFrames - 1].timestampMs, expectedFrames - 1);
      expect(tokens.last.isEndOfChunk, isTrue);
      expect(tokens.last.timestampMs, numFrames);
      // Omitting the range decodes the whole window.
      tokens = ctcWindowTokens(logits, numFrames: numFrames, vocabSize: 2);
      expect(tokens.length, numFrames + 1);
      // Fractions outside (0, 1) mean "decode everything".
      tokens = ctcWindowTokens(
        logits,
        numFrames: numFrames,
        vocabSize: 2,
        validFraction: 0,
      );
      expect(tokens.length, numFrames + 1);
    });
  });

  group('this port', () {
    // Frames: 0 0 1 1 2 2 0 3 (token per frame, vocab 4, blank 0).
    Float32List logitsFor(List<int> ids) {
      final out = Float32List(ids.length * 4);
      for (var t = 0; t < ids.length; t++) {
        out[t * 4 + ids[t]] = 1;
      }
      return out;
    }

    final ids = [0, 0, 1, 1, 2, 2, 0, 3];

    test('repeats collapse and blanks are dropped, frames kept', () {
      final tokens = ctcWindowTokens(
        logitsFor(ids),
        numFrames: 8,
        vocabSize: 4,
        blankId: 0,
      );
      expect(
        [for (final t in tokens) (t.tokenId, t.timestampMs)],
        [(1, 2), (2, 4), (3, 7), (-1, 8)],
      );
    });

    test('startFraction collapses from frame 0 and reports from its frame', () {
      // floor(0.375 * 8) = 3: the token 1 started at frame 2 is not reported
      // again at frame 3; times count from frame 3.
      final tokens = ctcWindowTokens(
        logitsFor(ids),
        numFrames: 8,
        vocabSize: 4,
        startFraction: 0.375,
        blankId: 0,
      );
      expect(
        [for (final t in tokens) (t.tokenId, t.timestampMs)],
        [(2, 1), (3, 4), (-1, 5)],
      );
    });

    test('a NaN logit fails the window', () {
      final logits = logitsFor(ids)..[13] = double.nan;
      expect(
        () => ctcWindowTokens(logits, numFrames: 8, vocabSize: 4),
        throwsStateError,
      );
    });

    test('bad sizes throw', () {
      expect(
        () => ctcWindowTokens(Float32List(4), numFrames: 2, vocabSize: 0),
        throwsArgumentError,
      );
      expect(
        () => ctcWindowTokens(Float32List(4), numFrames: 2, vocabSize: 4),
        throwsArgumentError,
      );
    });
  });
}
