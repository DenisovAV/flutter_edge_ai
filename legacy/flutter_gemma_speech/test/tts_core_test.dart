// Pure-Dart coverage of TtsCore's non-native helper math: searchSortedRight
// (Glow-TTS length-regulator lookup), tSin (CFM decoder timestep embedding),
// and nextGaussian's determinism under a fixed seed. No native FFI call is
// made anywhere in this file (TtsCore.load/LiteRtBindings.open are never
// invoked) — mirrors stt_pipeline_test.dart's "no native in unit tests"
// constraint. These pin the exact values ported from `matcha_synth.dart` so
// a future refactor can't silently drift the math the Phase-3 golden
// depends on.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/litert/tts_core.dart'
    show TtsCore, nextGaussian, searchSortedRight, tSin, ttsCfmSeed;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('searchSortedRight', () {
    test('finds the leftmost bucket where cum[i-1] <= v < cum[i]', () {
      final cum = Float64List.fromList([1.0, 3.0, 3.0, 6.0, 10.0]);
      expect(searchSortedRight(cum, 0.0), 0);
      expect(searchSortedRight(cum, 1.0), 1);
      expect(searchSortedRight(cum, 2.5), 1);
      // Ties (3.0 appears twice) land past both equal entries — side='right'.
      expect(searchSortedRight(cum, 3.0), 3);
      expect(searchSortedRight(cum, 9.9), 4);
    });

    test('a value at or past the last cumulative sum returns length', () {
      final cum = Float64List.fromList([2.0, 4.0]);
      expect(searchSortedRight(cum, 4.0), 2);
      expect(searchSortedRight(cum, 100.0), 2);
    });

    test('a value below the first bucket returns 0', () {
      final cum = Float64List.fromList([5.0, 8.0]);
      expect(searchSortedRight(cum, -1.0), 0);
    });
  });

  group('tSin', () {
    test('default half=80 produces a length-160 embedding', () {
      final emb = tSin(0.0);
      expect(emb.length, 160);
    });

    test('t=0.0: sin half is all zeros, cos half is all ones', () {
      final emb = tSin(0.0, half: 4);
      expect(emb.length, 8);
      for (var i = 0; i < 4; i++) {
        expect(emb[i], closeTo(0.0, 1e-9));
      }
      for (var i = 4; i < 8; i++) {
        expect(emb[i], closeTo(1.0, 1e-9));
      }
    });

    test('first sin/cos pair matches the raw sinusoid at t=1.0', () {
      // half=80: e[0] = 1000 * t * exp(0) = 1000 * t.
      final emb = tSin(1.0);
      expect(emb[0], closeTo(math.sin(1000.0), 1e-6));
      expect(emb[80], closeTo(math.cos(1000.0), 1e-6));
    });
  });

  group('nextGaussian', () {
    test('ttsCfmSeed is the documented fixed seed', () {
      expect(ttsCfmSeed, 1234);
    });

    test('is deterministic: same seed produces the same sequence', () {
      final a = math.Random(ttsCfmSeed);
      final b = math.Random(ttsCfmSeed);
      final seqA = List.generate(20, (_) => nextGaussian(a));
      final seqB = List.generate(20, (_) => nextGaussian(b));
      expect(seqA, seqB);
    });

    test('produces finite, non-constant samples', () {
      final rnd = math.Random(ttsCfmSeed);
      final samples = List.generate(50, (_) => nextGaussian(rnd));
      expect(samples.every((s) => s.isFinite), isTrue);
      expect(samples.toSet().length, greaterThan(1));
    });
  });

  // TtsCore.planMelWindows is pure (no model/native call): it only greedily
  // packs a Float64List of per-phoneme durations into contiguous windows
  // that each fit maxMel. This is the new logic the MAX_MEL chunked-decode
  // fix depends on, so it's tested directly here without any FFI/model.
  group('planMelWindows', () {
    test('all phonemes fit -> a single window covering [0, realCount)', () {
      final w = Float64List.fromList([2.0, 2.0, 2.0]);
      final windows = TtsCore.planMelWindows(w, 3, 10);
      expect(windows, [(0, 3)]);
    });

    test('durations that overflow -> tiled windows, no gap/overlap', () {
      // maxMel=10, w=[4,4,4,4]: window 1 takes phonemes 0,1 (sum 8; adding
      // phoneme 2 would make 12 > 10) -> (0,2); window 2 takes 2,3 -> (2,4).
      final w = Float64List.fromList([4.0, 4.0, 4.0, 4.0]);
      final windows = TtsCore.planMelWindows(w, 4, 10);
      expect(windows, [(0, 2), (2, 4)]);

      // Full coverage, no gap/overlap, each window's summed duration <= maxMel.
      var covered = 0;
      for (final (s, e) in windows) {
        expect(s, covered);
        var sum = 0.0;
        for (var p = s; p < e; p++) {
          sum += w[p];
        }
        expect(sum, lessThanOrEqualTo(10.0));
        covered = e;
      }
      expect(covered, 4);
    });

    test('irregular durations still tile with each window <= maxMel', () {
      // maxMel=10, w=[3,5,6,1,9]: (0,1)=3 ok, +5=8 ok, +6=14>10 -> break at 2
      // -> (0,2). Then start=2: 6, +1=7, +9=16>10 -> break at 4 -> (2,4).
      // Then start=4: 9 -> (4,5).
      final w = Float64List.fromList([3.0, 5.0, 6.0, 1.0, 9.0]);
      final windows = TtsCore.planMelWindows(w, 5, 10);
      expect(windows, [(0, 2), (2, 4), (4, 5)]);
    });

    test('a single phoneme duration > maxMel throws StateError', () {
      final w = Float64List.fromList([2.0, 20.0, 2.0]);
      expect(
        () => TtsCore.planMelWindows(w, 3, 10),
        throwsA(isA<StateError>()),
      );
    });

    test('a single phoneme duration exactly == maxMel does not throw', () {
      final w = Float64List.fromList([10.0]);
      final windows = TtsCore.planMelWindows(w, 1, 10);
      expect(windows, [(0, 1)]);
    });

    test('realCount == 0 -> empty window list', () {
      final w = Float64List.fromList([4.0, 4.0, 4.0, 4.0]);
      final windows = TtsCore.planMelWindows(w, 0, 10);
      expect(windows, isEmpty);
    });
  });

  // TtsCore.concatSegments is the pure helper the multi-window branch of
  // synthesize() delegates to (extracted so it's unit-testable without
  // native): back-to-back concat, NO inter-segment silence (unlike the
  // worker's clause-level concatPcmWithSilence).
  group('concatSegments', () {
    test('output length equals the sum of the segment lengths', () {
      final segs = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5]),
        Uint8List.fromList([6]),
      ];
      expect(TtsCore.concatSegments(segs).length, 6);
    });

    test('bytes are laid down in order with no gap', () {
      final segs = [
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3, 4, 5]),
      ];
      expect(TtsCore.concatSegments(segs), [1, 2, 3, 4, 5]);
    });

    test('empty list -> empty output', () {
      expect(TtsCore.concatSegments(<Uint8List>[]), isEmpty);
    });

    test('single segment -> that segment\'s bytes, unchanged', () {
      final seg = Uint8List.fromList([7, 8, 9]);
      expect(TtsCore.concatSegments([seg]), [7, 8, 9]);
    });
  });
}
