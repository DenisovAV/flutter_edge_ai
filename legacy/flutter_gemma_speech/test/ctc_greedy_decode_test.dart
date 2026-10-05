import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/litert/stt_core.dart'
    show ctcGreedyDecode;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ctcGreedyDecode', () {
    test('collapses consecutive duplicates, then drops the blank id', () {
      // 4 frames, 5 classes, blankId=4.
      // frame0 argmax=2, frame1 argmax=2 (dup), frame2 argmax=4 (blank),
      // frame3 argmax=1. Collapse: [2,2,4,1] -> [2,4,1]. Drop blank(4): [2,1].
      final logits = Float32List.fromList([
        0.1, 0.2, 0.9, 0.1, 0.05, // frame0 -> 2
        0.05, 0.1, 0.95, 0.2, 0.1, // frame1 -> 2 (dup)
        0.1, 0.1, 0.1, 0.1, 0.9, // frame2 -> 4 (blank)
        0.1, 0.8, 0.2, 0.1, 0.05, // frame3 -> 1
      ]);
      final ids = ctcGreedyDecode(
        logits,
        blankId: 4,
        numFrames: 4,
        numClasses: 5,
      );
      expect(ids, [2, 1]);
    });

    test('all-blank frames collapse to an empty list', () {
      final logits = Float32List.fromList([
        0.1, 0.1, 0.9, // frame0 -> 2 (blank)
        0.1, 0.1, 0.9, // frame1 -> 2 (blank, dup, collapses first anyway)
      ]);
      final ids = ctcGreedyDecode(
        logits,
        blankId: 2,
        numFrames: 2,
        numClasses: 3,
      );
      expect(ids, isEmpty);
    });

    test(
      'non-adjacent repeats are NOT merged (collapse is adjacency-only)',
      () {
        // frame0 -> 1, frame1 -> 2, frame2 -> 1. No blanks. Collapse only
        // removes ADJACENT duplicates, so [1,2,1] survives unchanged.
        final logits = Float32List.fromList([
          0.1, 0.9, 0.1, // frame0 -> 1
          0.1, 0.1, 0.9, // frame1 -> 2
          0.1, 0.9, 0.1, // frame2 -> 1
        ]);
        final ids = ctcGreedyDecode(
          logits,
          blankId: 99, // never fires
          numFrames: 3,
          numClasses: 3,
        );
        expect(ids, [1, 2, 1]);
      },
    );

    test('a blank between two equal ids preserves both (collapse BEFORE '
        'blank-drop, not after)', () {
      // frame0 -> 1, frame1 -> 2 (blank), frame2 -> 1. Collapse first sees
      // no adjacent duplicates ([1,2,1] unchanged, per the previous test),
      // THEN blank(2) is dropped: [1,1]. The wrong ordering (drop blanks
      // first, collapse second) would instead see [1,1] pre-collapse and
      // wrongly merge them into a single [1].
      final logits = Float32List.fromList([
        0.1, 0.9, 0.1, // frame0 -> 1
        0.1, 0.1, 0.9, // frame1 -> 2 (blank)
        0.1, 0.9, 0.1, // frame2 -> 1
      ]);
      final ids = ctcGreedyDecode(
        logits,
        blankId: 2,
        numFrames: 3,
        numClasses: 3,
      );
      expect(ids, [1, 1]);
    });

    test('a NaN winning logit fails loud instead of emitting a garbled id', () {
      // A corrupted frame (GPU/NPU accelerator failure, cf. #214): the winning
      // logit is NaN. `argmax`'s `>` comparison is NaN-blind, so without the
      // guard this frame would silently contribute a plausible-but-wrong id and
      // the whole transcript would be returned as "successful" garbage. The
      // guard must throw instead — matching the seq2seq _decodeLoop NaN check.
      final logits = Float32List.fromList([
        double.nan, 0.2, 0.1, // frame0 -> argmax 0, whose logit is NaN
        0.1, 0.9, 0.1, // frame1 -> 1
      ]);
      expect(
        () => ctcGreedyDecode(logits, blankId: 2, numFrames: 2, numClasses: 3),
        throwsStateError,
      );
    });

    test('a NaN AWAY from the argmax winner still fails loud (whole-frame scan, '
        'not just the winning logit)', () {
      // The subtle case: the true max is a real value, but another class in the
      // frame is NaN. argmax is NaN-blind so it returns the real winner, and a
      // winner-only check (row[argmax]) would silently accept the frame. The
      // guard must scan the whole frame and still throw.
      final logits = Float32List.fromList([
        0.1, double.nan, 0.9, // frame0 -> argmax 2 (real 0.9); NaN at index 1
        0.1, 0.8, 0.1, // frame1 -> 1
      ]);
      expect(
        () => ctcGreedyDecode(logits, blankId: 5, numFrames: 2, numClasses: 3),
        throwsStateError,
      );
    });
  });
}
