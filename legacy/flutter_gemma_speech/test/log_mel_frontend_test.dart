import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/litert/log_mel_frontend.dart';
import 'package:flutter_gemma_speech/src/litert/mel_filter_assets.dart';
import 'package:flutter_test/flutter_test.dart';

int _argmaxOf(List<double> values) {
  var bestIndex = 0;
  var bestValue = values[0];
  for (var i = 1; i < values.length; i++) {
    if (values[i] > bestValue) {
      bestValue = values[i];
      bestIndex = i;
    }
  }
  return bestIndex;
}

void main() {
  group('applyHannWindow', () {
    test('endpoints are near zero, center is near one (periodic Hann)', () {
      final w = applyHannWindow(Float32List(400)..fillRange(0, 400, 1.0));
      expect(w.length, 400);
      expect(w[0], closeTo(0.0, 1e-6));
      expect(w[200], closeTo(1.0, 0.02));
    });
  });

  group('powerSpectrum', () {
    test(
      'peaks at the correct bin for a pure 2000 Hz tone at 16 kHz, nFft=400',
      () {
        const nFft = 400;
        const sampleRate = 16000;
        const freqHz = 2000.0; // expected bin = freqHz * nFft / sampleRate = 50
        final frame = Float32List(nFft);
        for (var n = 0; n < nFft; n++) {
          frame[n] = math.sin(2 * math.pi * freqHz * n / sampleRate);
        }
        final windowed = applyHannWindow(frame);
        final power = powerSpectrum(windowed, nFft);
        expect(power.length, nFft ~/ 2 + 1);
        expect(_argmaxOf(power), 50);
      },
    );

    test('DC input concentrates all energy in bin 0', () {
      final frame = Float32List(400)..fillRange(0, 400, 1.0);
      final power = powerSpectrum(frame, 400); // no window, pure DC
      expect(_argmaxOf(power), 0);
      expect(power[0], greaterThan(power[1] * 100));
    });
  });

  group('stftFrames', () {
    test('produces exactly melFrames windows of length nFft', () {
      final pcm = Float32List(16000); // 1 s @ 16 kHz
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = math.sin(2 * math.pi * 440.0 * i / 16000);
      }
      final frames = stftFrames(pcm, nFft: 400, hopLength: 160, melFrames: 100);
      expect(frames.length, 100);
      for (final f in frames) {
        expect(f.length, 400);
      }
    });

    test(
      'first frame is centered on sample 0 via reflect padding (not zero padding)',
      () {
        // A short DC clip: reflect-padding a constant signal reproduces the
        // same constant (unlike zero-padding, which would introduce an edge
        // discontinuity) -- the first NFT/2 samples of frame 0 mirror-image the
        // clip's own start, so for a constant signal frame 0 is uniformly 1.0
        // pre-window.
        final pcm = Float32List(16000)..fillRange(0, 16000, 1.0);
        final frames = stftFrames(pcm, nFft: 400, hopLength: 160, melFrames: 1);
        final windowed = frames[0];
        // frames[0] is already Hann-windowed (per stftFrames' contract), and
        // the periodic Hann window is exactly zero at index 0 regardless of
        // padding strategy, so index 0 can't discriminate reflect- vs
        // zero-padding. Index 100 sits inside the reflect-padded prefix
        // (indices 0..199) away from that edge zero: a zero-padded
        // implementation would show 0.0 there, while reflect-padding mirrors
        // the clip's own 1.0s into that region.
        expect(windowed[100], isNot(0.0));
      },
    );
  });

  group(
    'computeLogMelSpectrogram (golden vs Python openai-whisper reference)',
    () {
      test(
        'matches the Python reference within tolerance for a 1s 440Hz tone',
        () {
          final fixtureText = File(
            'test/fixtures/log_mel_golden_1s_440hz.json',
          ).readAsStringSync();
          final fixture = jsonDecode(fixtureText) as Map<String, dynamic>;
          final sampleRate = fixture['sampleRate'] as int;
          final n = fixture['samples'] as int;
          final toneHz = (fixture['toneHz'] as num).toDouble();
          final amplitude = (fixture['toneAmplitude'] as num).toDouble();
          final expected = (fixture['melFirstFlat'] as List)
              .map((v) => (v as num).toDouble())
              .toList();

          final pcm = Float32List(n);
          for (var i = 0; i < n; i++) {
            pcm[i] =
                amplitude * math.sin(2 * math.pi * toneHz * i / sampleRate);
          }

          final melFilters = loadMelFilterAsset('whisper_mel_80');
          final actual = computeLogMelSpectrogram(
            pcm,
            nFft: fixture['nFft'] as int,
            hopLength: fixture['hopLength'] as int,
            nMels: fixture['nMels'] as int,
            melFrames: fixture['melFrames'] as int,
            melFilters: melFilters,
            normalization: SttMelNormalization.whisper,
          );

          expect(actual.length, expected.length);
          var maxAbsDiff = 0.0;
          for (var i = 0; i < actual.length; i++) {
            final diff = (actual[i] - expected[i]).abs();
            if (diff > maxAbsDiff) maxAbsDiff = diff;
          }
          // Direct DFT vs torch's FFT + float32 vs float64 accumulation over 400
          // terms/bin; normalized values are roughly in [-1, ~1] after whisper's
          // (x+4)/4 scaling, so 1e-2 absolute is generous enough to tolerate
          // implementation-level float noise while still catching a genuinely
          // wrong STFT/filterbank/normalization (which would be off by >> 1e-2).
          expect(
            maxAbsDiff,
            lessThan(1e-2),
            reason: 'max abs diff: $maxAbsDiff',
          );
        },
      );
    },
  );

  group(
    'hannWindowSymmetric (periodic=False, distinct from applyHannWindow)',
    () {
      test('endpoints are exactly zero; symmetric peak near the midpoint', () {
        final w = hannWindowSymmetric(400);
        expect(w.length, 400);
        expect(w[0], 0.0);
        expect(w[399], 0.0);
        expect(w[199], closeTo(0.9999845014267927, 1e-6));
        expect(w[200], closeTo(0.9999845014267927, 1e-6));
      });
    },
  );

  group('applyPreemphasis', () {
    test('y[0]=x[0]; y[n]=x[n]-0.97*x[n-1] otherwise', () {
      final x = Float32List.fromList([1.0, 2.0, 4.0, 8.0, 16.0]);
      final y = applyPreemphasis(x, 0.97);
      expect(y.length, 5);
      expect(y[0], closeTo(1.0, 1e-4));
      expect(y[1], closeTo(1.03, 1e-4));
      expect(y[2], closeTo(2.06, 1e-4));
      expect(y[3], closeTo(4.12, 1e-4));
      expect(y[4], closeTo(8.24, 1e-4));
    });

    test('empty input returns empty output', () {
      expect(applyPreemphasis(Float32List(0), 0.97), isEmpty);
    });
  });

  group('centerWindowInBuffer', () {
    test(
      'centers a 400-sample window into a 512-sample buffer: 56 zeros each side',
      () {
        final w400 = hannWindowSymmetric(400);
        final centered = centerWindowInBuffer(w400, 512);
        expect(centered.length, 512);
        // True zero-padding region (outside the window's own [56,455] extent,
        // which itself happens to be zero at its own two edges, 56 and 455 --
        // so these indices are chosen just OUTSIDE that coincidental overlap).
        expect(centered[55], 0.0);
        expect(centered[456], 0.0);
        // A definitively nonzero, mid-window sample, offset by the 56-zero pad.
        expect(centered[56 + 199], closeTo(0.9999845014267927, 1e-6));
      },
    );
  });

  group('nemoStftFrames', () {
    test('produces exactly melFrames windows of length nFft', () {
      final pcm = Float32List(16000); // 1 s @ 16 kHz
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = math.sin(2 * math.pi * 440.0 * i / 16000);
      }
      final centeredWindow = centerWindowInBuffer(
        hannWindowSymmetric(400),
        512,
      );
      final frames = nemoStftFrames(
        pcm,
        nFft: 512,
        hopLength: 160,
        melFrames: 100,
        centeredWindow: centeredWindow,
      );
      expect(frames.length, 100);
      for (final f in frames) {
        expect(f.length, 512);
      }
    });

    test('first frame is centered via reflect padding (not zero padding)', () {
      // A constant DC clip: reflect-padding preserves the constant all the way
      // through the padded prefix; zero-padding would show a 0.0 there
      // instead. Index 100 sits inside the true reflect-padded prefix
      // (padAmt=nFft/2=256) AND inside the centered window's nonzero span
      // (local index 100-56=44, strictly inside the open interval where the
      // periodic=False Hann window is nonzero) -- discriminating the two.
      final pcm = Float32List(16000)..fillRange(0, 16000, 1.0);
      final centeredWindow = centerWindowInBuffer(
        hannWindowSymmetric(400),
        512,
      );
      final frames = nemoStftFrames(
        pcm,
        nFft: 512,
        hopLength: 160,
        melFrames: 1,
        centeredWindow: centeredWindow,
      );
      expect(frames[0][100], isNot(0.0));
    });
  });

  group('computeNemoLogMel (golden vs Python NeMo-recipe reference)', () {
    test('matches the Python reference within tolerance for a 1s 440Hz tone', () {
      final fixtureText = File(
        'test/fixtures/nemo_log_mel_golden_1s_440hz.json',
      ).readAsStringSync();
      final fixture = jsonDecode(fixtureText) as Map<String, dynamic>;
      final sampleRate = fixture['sampleRate'] as int;
      final n = fixture['samples'] as int;
      final toneHz = (fixture['toneHz'] as num).toDouble();
      final amplitude = (fixture['toneAmplitude'] as num).toDouble();
      final expected = (fixture['frameFirstFlat'] as List)
          .map((v) => (v as num).toDouble())
          .toList();

      final pcm = Float32List(n);
      for (var i = 0; i < n; i++) {
        pcm[i] = amplitude * math.sin(2 * math.pi * toneHz * i / sampleRate);
      }

      final melFilters = loadMelFilterAsset('nemo_mel_80');
      final actual = computeNemoLogMel(
        pcm,
        nFft: fixture['nFft'] as int,
        winLength: fixture['winLength'] as int,
        hopLength: fixture['hopLength'] as int,
        preemphasis: (fixture['preemphasis'] as num).toDouble(),
        nMels: fixture['nMels'] as int,
        melFrames: fixture['melFrames'] as int,
        melFilters: melFilters,
      );

      expect(actual.length, expected.length);
      var maxAbsDiff = 0.0;
      for (var i = 0; i < actual.length; i++) {
        final diff = (actual[i] - expected[i]).abs();
        if (diff > maxAbsDiff) maxAbsDiff = diff;
      }
      // Direct DFT (Dart) vs numpy's FFT (Python reference) + float32 vs
      // float64 accumulation over 257 bins/mel, then divided by a per-bin std
      // (which amplifies small numerator diffs when std is small). The measured
      // float-noise floor for the CORRECT (ddof=1) code vs this golden is
      // ~1.6e-5 (worst bin). The ddof CONVENTION itself moves the values by
      // ~5e-2 at this fixture's melFrames=100 (population ÷N vs sample ÷(N-1)).
      // Tolerance is 1e-3 — the log-midpoint between the two — so the test
      // PASSES the correct ddof=1 code (1.6e-5) but FAILS a revert to ddof=0
      // (~5e-2). It therefore genuinely discriminates the normalization
      // CONVENTION, not merely gross STFT/mel/log errors. Do NOT loosen back
      // toward 5e-2: at 5e-2 the ddof=0 divergence (0.0499) slips under the
      // bound and the test stops distinguishing population from sample std.
      //
      // Convention note: this fixture pins the Bessel-corrected ddof=1 (sample
      // std) z-score, matching real NVIDIA/NeMo and what computeNemoLogMel now
      // computes. It is (re)generated by the INDEPENDENT numpy reference
      // test/fixtures/gen_nemo_log_mel_golden.py — which derives the z-score
      // from numpy's own std, NOT from this Dart code — so this test genuinely
      // discriminates the convention rather than encoding it. Regenerate the
      // fixture with that script if the recipe ever changes.
      expect(maxAbsDiff, lessThan(1e-3), reason: 'max abs diff: $maxAbsDiff');
    });

    test('all-silence input stays finite (per-bin std-floor guards the '
        'z-score division by zero)', () {
      // A silent clip makes every log-mel value identical per bin, so the raw
      // per-bin std is exactly 0. Without the 1e-5 floor the z-score would be
      // 0/0 = NaN for every element and the CTC path would argmax garbage. This
      // pins the floor: silence -> all-finite (in fact all-zero) features.
      final melFilters = loadMelFilterAsset('nemo_mel_80');
      final silence = Float32List(16000); // 1 s of zeros @ 16 kHz
      final out = computeNemoLogMel(
        silence,
        nFft: 512,
        winLength: 400,
        hopLength: 160,
        preemphasis: 0.97,
        nMels: 80,
        melFrames: 100,
        melFilters: melFilters,
      );
      expect(out.length, 100 * 80);
      expect(
        out.every((v) => v.isFinite),
        isTrue,
        reason: 'silence must not produce NaN/inf features',
      );
    });
  });
}
