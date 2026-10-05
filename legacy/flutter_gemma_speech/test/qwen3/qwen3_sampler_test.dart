// Tests for the Qwen3-TTS talker sampler + cb0 scoring
// (`lib/src/qwen3/qwen3_sampler.dart`).
//
// Pure unit tests — no model tables, no artifacts, no `@Tags` skip-guard.
// Every input is a small hand-constructed vector so the expected output can
// be hand-checked against the recipe's arithmetic — `synthesize`'s
// `suppress`/scoring edits and `_pick`, both on `Qwen3TtsPipeline` in the
// recipe's `qwen3_tts_pipeline.py`.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/qwen3/qwen3_sampler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pickGreedy', () {
    test('returns the argmax index', () {
      final logits = Float32List.fromList([1.0, 5.0, 3.0, -2.0]);
      expect(pickGreedy(logits), 1);
    });

    test('ties resolve to the lowest index (matches numpy argmax)', () {
      final logits = Float32List.fromList([2.0, 4.0, 4.0, 4.0, 0.0]);
      expect(pickGreedy(logits), 1);
    });

    test('single-element array returns index 0', () {
      final logits = Float32List.fromList([7.0]);
      expect(pickGreedy(logits), 0);
    });

    test('all-negative logits still pick the argmax', () {
      final logits = Float32List.fromList([-5.0, -1.0, -3.0]);
      expect(pickGreedy(logits), 1);
    });
  });

  group('buildSuppress', () {
    test('is zero for every index < 2048', () {
      final suppress = buildSuppress();
      expect(suppress.length, 3072);
      for (var i = 0; i < 2048; i++) {
        expect(suppress[i], 0.0, reason: 'index $i');
      }
    });

    test('is zero at the codec EOS index (2150)', () {
      final suppress = buildSuppress();
      expect(suppress[2150], 0.0);
    });

    test('is -1e9 for every index >= 2048 except EOS', () {
      final suppress = buildSuppress();
      for (var i = 2048; i < suppress.length; i++) {
        if (i == 2150) continue;
        expect(suppress[i], -1e9, reason: 'index $i');
      }
    });
  });

  group('applyCb0Scoring', () {
    test('adds suppress element-wise into scores (no guard, no history)', () {
      // suppress[1] uses -50.0 rather than -1e9 here so the sum is exactly
      // representable in float32 (the -1e9 magnitude is covered by the
      // dedicated "dominates" test below, where float32's ~64-wide step
      // size at that magnitude legitimately rounds small additions away).
      final scores = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
      final suppress = Float32List.fromList([0.0, -50.0, 0.0, 10.0]);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: <int>{},
        repetitionPenalty: 1.3,
        minNewTokensGuard: false,
      );
      expect(scores[0], 1.0);
      expect(scores[1], -48.0);
      expect(scores[2], 3.0);
      expect(scores[3], 14.0);
    });

    test('a real -1e9 suppress entry dominates the sum (float32 '
        'precision — the recipe stores scores as float32)', () {
      final scores = Float32List.fromList([2.0]);
      final suppress = Float32List.fromList([-1e9]);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: <int>{},
        repetitionPenalty: 1.3,
        minNewTokensGuard: false,
      );
      expect(scores[0], -1e9);
    });

    test('minNewTokensGuard forces EOS (2150) to -1e9', () {
      final scores = Float32List(3072);
      scores[2150] = 42.0; // would otherwise survive untouched
      final suppress = Float32List(3072); // all-zero: isolate the guard
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: <int>{},
        repetitionPenalty: 1.3,
        minNewTokensGuard: true,
      );
      expect(scores[2150], -1e9);
    });

    test('guard is a no-op when false', () {
      final scores = Float32List(3072);
      scores[2150] = 42.0;
      final suppress = Float32List(3072);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: <int>{},
        repetitionPenalty: 1.3,
        minNewTokensGuard: false,
      );
      expect(scores[2150], 42.0);
    });

    test('repetition penalty: positive score divides by the penalty', () {
      final scores = Float32List.fromList([10.0, 0.0, 0.0, 0.0]);
      final suppress = Float32List(4);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: {0},
        repetitionPenalty: 2.0,
        minNewTokensGuard: false,
      );
      // s=10 > 0 -> 10 / 2.0 = 5.0
      expect(scores[0], 5.0);
    });

    test('repetition penalty: non-positive score multiplies by the '
        'penalty', () {
      final scores = Float32List.fromList([-4.0, 0.0, 0.0, 0.0]);
      final suppress = Float32List(4);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: {0},
        repetitionPenalty: 2.0,
        minNewTokensGuard: false,
      );
      // s=-4 is not > 0 -> -4 * 2.0 = -8.0
      expect(scores[0], -8.0);
    });

    test('repetition penalty: exact-zero score takes the multiply branch '
        '(s > 0 is false at s == 0)', () {
      final scores = Float32List.fromList([0.0, 0.0, 0.0, 0.0]);
      final suppress = Float32List(4);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: {0},
        repetitionPenalty: 3.0,
        minNewTokensGuard: false,
      );
      // s=0 is not > 0 -> 0 * 3.0 = 0.0 (same result, but exercises the
      // multiply branch's condition rather than the divide branch's).
      expect(scores[0], 0.0);
    });

    test('repetition penalty applies to every token in history, others '
        'untouched', () {
      final scores = Float32List.fromList([8.0, -6.0, 3.0, 0.0]);
      final suppress = Float32List(4);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: {0, 1},
        repetitionPenalty: 2.0,
        minNewTokensGuard: false,
      );
      expect(scores[0], 4.0); // 8 / 2
      expect(scores[1], -12.0); // -6 * 2
      expect(scores[2], 3.0); // untouched (not in history)
      expect(scores[3], 0.0); // untouched (not in history)
    });

    test('full pipeline: suppress + guard + repetition penalty compose in '
        'the recipe order', () {
      // scores = logits + suppress; then guard; then repetition penalty.
      final scores = Float32List.fromList([5.0, 5.0, 5.0]); // "logits"
      final suppress = Float32List.fromList([0.0, 0.0, -1e9]);
      applyCb0Scoring(
        scores,
        suppress: suppress,
        history: {0},
        repetitionPenalty: 5.0,
        minNewTokensGuard: false,
      );
      // index 0: (5+0)=5, in history, >0 -> 5/5 = 1.0
      expect(scores[0], 1.0);
      // index 1: (5+0)=5, not in history -> untouched
      expect(scores[1], 5.0);
      // index 2: (5 + -1e9), not in history -> untouched by penalty.
      // float32 storage rounds this sum back to exactly -1e9 (the +5 is
      // far below the ~64-wide float32 step size at that magnitude).
      expect(scores[2], -1e9);
    });
  });

  group('pickSampled', () {
    test('with topK=1 always returns the argmax regardless of rng draw', () {
      final logits = Float32List.fromList([1.0, 9.0, 2.0, 0.0]);
      for (final seed in [1, 2, 3, 4, 5]) {
        final picked = pickSampled(
          logits,
          topK: 1,
          temperature: 1.0,
          rng: Random(seed),
        );
        expect(picked, 1);
      }
    });

    test('stays within the top-k index set for a seeded rng', () {
      final logits = Float32List.fromList([0.0, 10.0, 9.0, 8.0, -5.0, -6.0]);
      const topKIndices = {1, 2, 3}; // the 3 highest logits
      final rng = Random(42);
      for (var i = 0; i < 50; i++) {
        final picked = pickSampled(logits, topK: 3, temperature: 1.0, rng: rng);
        expect(topKIndices.contains(picked), isTrue, reason: 'picked $picked');
      }
    });

    test('is reproducible for the same seed', () {
      final logits = Float32List.fromList([1.0, 2.0, 3.0, 4.0, 5.0]);
      final picksA = [
        for (var i = 0; i < 20; i++)
          pickSampled(logits, topK: 0, temperature: 1.0, rng: Random(7)),
      ];
      // Random(7) is re-seeded per element above, so instead compare two
      // independently-seeded runs draw-for-draw using a shared rng stream.
      final rngA = Random(123);
      final seqA = [
        for (var i = 0; i < 20; i++)
          pickSampled(logits, topK: 0, temperature: 1.0, rng: rngA),
      ];
      final rngB = Random(123);
      final seqB = [
        for (var i = 0; i < 20; i++)
          pickSampled(logits, topK: 0, temperature: 1.0, rng: rngB),
      ];
      expect(seqA, orderedEquals(seqB));
      // Sanity: every single-seed-per-call draw above also lands in range.
      expect(picksA.every((p) => p >= 0 && p < logits.length), isTrue);
    });

    test('topK=0 (no cutoff) never picks the effectively-impossible tail '
        'when logits are extremely skewed, but does not throw', () {
      final logits = Float32List.fromList([100.0, -100.0, -100.0]);
      final picked = pickSampled(
        logits,
        topK: 0,
        temperature: 1.0,
        rng: Random(99),
      );
      expect(picked, 0);
    });

    test('topK >= logits.length is treated as "no cutoff"', () {
      final logits = Float32List.fromList([1.0, 2.0, 3.0]);
      final picked = pickSampled(
        logits,
        topK: 3,
        temperature: 1.0,
        rng: Random(5),
      );
      expect(picked, inInclusiveRange(0, 2));
    });

    test('empty logits throws', () {
      expect(
        () => pickSampled(
          Float32List(0),
          topK: 0,
          temperature: 1.0,
          rng: Random(1),
        ),
        throwsArgumentError,
      );
    });
  });
}
