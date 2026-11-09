import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_edge_ai_speech/src/litert/log_mel_frontend.dart';
import 'package:flutter_edge_ai_speech/src/litert/mel_filter_assets.dart';
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

/// The direct DFT that [powerSpectrum] replaced (#784), kept verbatim as the
/// oracle: the Bluestein path must agree with it for the nFft the profiles use
/// (whisper 400, parakeet 512) and for others. Deliberately the naive
/// O(nFft^2) loop — an FFT checked against an FFT would prove nothing.
Float32List _directDftPowerSpectrum(Float32List windowedFrame, int nFft) {
  final nBins = nFft ~/ 2 + 1;
  final power = Float32List(nBins);
  for (var k = 0; k < nBins; k++) {
    var re = 0.0, im = 0.0;
    final angleStep = -2 * math.pi * k / nFft;
    for (var t = 0; t < nFft; t++) {
      final angle = angleStep * t;
      re += windowedFrame[t] * math.cos(angle);
      im += windowedFrame[t] * math.sin(angle);
    }
    power[k] = re * re + im * im;
  }
  return power;
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

    // Sizes no profile uses: n=1 (an FFT of length 1), odd lengths, and powers
    // of two, where M = 2*nFft is the tightest no-alias size.
    test('agrees with the direct DFT oracle for other sizes', () {
      final random = math.Random(815);
      for (final nFft in [1, 2, 3, 7, 256, 257, 1024]) {
        for (var frame = 0; frame < 4; frame++) {
          final samples = Float32List(nFft);
          for (var i = 0; i < nFft; i++) {
            samples[i] = random.nextDouble() * 2 - 1;
          }
          final expected = _directDftPowerSpectrum(samples, nFft);
          final actual = powerSpectrum(samples, nFft);
          expect(actual.length, expected.length, reason: 'nFft=$nFft');
          for (var k = 0; k < expected.length; k++) {
            final tolerance = 1e-5 * math.max(expected[k].abs(), 1.0);
            expect(
              (actual[k] - expected[k]).abs(),
              lessThanOrEqualTo(tolerance),
              reason: 'nFft=$nFft frame=$frame bin=$k',
            );
          }
        }
      }
    });

    test('rejects a frame that is not nFft long', () {
      expect(() => powerSpectrum(Float32List(401), 400), throwsStateError);
      expect(() => powerSpectrum(Float32List(399), 400), throwsStateError);
      expect(() => powerSpectrum(Float32List(0), 0), throwsStateError);
    });

    for (final nFft in [400, 512]) {
      test('agrees with the direct DFT oracle for nFft=$nFft', () {
        // Random frames rather than a tone: a tone only lights up two bins, so
        // it would leave the chirp's leakage and the mirrored kernel untested.
        final random = math.Random(20261109 + nFft);
        for (var frame = 0; frame < 32; frame++) {
          final samples = Float32List(nFft);
          for (var i = 0; i < nFft; i++) {
            samples[i] = random.nextDouble() * 2 - 1;
          }
          final expected = _directDftPowerSpectrum(samples, nFft);
          final actual = powerSpectrum(samples, nFft);
          expect(actual.length, expected.length);
          for (var k = 0; k < expected.length; k++) {
            // Relative to the bin's own magnitude; a plain absolute epsilon
            // would be meaningless at whisper's power scale (~1e3).
            final tolerance = 1e-5 * math.max(expected[k].abs(), 1.0);
            expect(
              (actual[k] - expected[k]).abs(),
              lessThanOrEqualTo(tolerance),
              reason: 'nFft=$nFft frame=$frame bin=$k',
            );
          }
        }
      });
    }
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
          // Bluestein vs torch's FFT + float32 vs float64 accumulation over 400
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
      // Bluestein (Dart) vs numpy's FFT (Python reference) + float32 vs
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

  group('MelFilterSpans', () {
    // (asset, nBins, non-zero multiplies per frame). The counts are the point:
    // the bundled filterbanks are ~2.4% dense, which is why the windowed
    // projection is worth it. If an asset is regenerated, re-derive them.
    for (final (asset, nBins, multiplies) in [
      ('whisper_mel_80', 201, 391),
      ('nemo_mel_80', 257, 500),
    ]) {
      test('matches the dense matmul bit for bit ($asset)', () {
        const nMels = 80;
        final filters = loadMelFilterAsset(asset);
        expect(filters.length, nMels * nBins);
        final spans = MelFilterSpans(filters, nMels: nMels, nBins: nBins);
        expect(spans.multiplicationCount, multiplies);

        final random = math.Random(4242);
        for (var frame = 0; frame < 8; frame++) {
          final power = Float32List(nBins);
          for (var b = 0; b < nBins; b++) {
            power[b] = random.nextDouble() * 100;
          }
          final actual = Float32List(nMels);
          spans.apply(power, actual);
          // A dense reference that stores into float32 exactly as `apply`
          // does: the two must be the same bits, not merely close.
          final dense = Float32List(nMels);
          for (var m = 0; m < nMels; m++) {
            var sum = 0.0;
            for (var b = 0; b < nBins; b++) {
              sum += filters[m * nBins + b] * power[b];
            }
            dense[m] = sum;
          }
          expect(actual, dense, reason: '$asset frame=$frame');
        }
      });
    }

    // Neither bundled bank has a gap inside a filter, an empty row, or a
    // non-zero at the first or last bin, so a synthetic one covers those paths.
    test('matches the dense matmul on gaps, empty rows and edge bins', () {
      const nMels = 4, nBins = 6;
      final filters = Float32List.fromList([
        0.5, 0.0, 0.25, 0.0, 0.0, 0.0, // starts at bin 0, gap inside
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, // empty row
        0.0, 0.0, 0.0, 0.0, 0.75, 1.0, // ends at the last bin
        0.0, 0.125, 0.0, 0.0, 0.0, 0.5, // gap spanning most of the row
      ]);
      final spans = MelFilterSpans(filters, nMels: nMels, nBins: nBins);
      expect(spans.multiplicationCount, 3 + 0 + 2 + 5);
      final power = Float32List.fromList([1.5, 2.0, 3.0, 5.0, 7.0, 11.0]);
      final actual = Float32List(nMels);
      spans.apply(power, actual);
      final dense = Float32List(nMels);
      for (var m = 0; m < nMels; m++) {
        var sum = 0.0;
        for (var b = 0; b < nBins; b++) {
          sum += filters[m * nBins + b] * power[b];
        }
        dense[m] = sum;
      }
      expect(actual, dense);
      expect(actual, [0.75 + 0.75, 0.0, 5.25 + 11.0, 0.25 + 5.5]);
    });

    // StateError, not ArgumentError: the STT worker reports an ArgumentError to
    // the app as a bad transcribe argument. It also tells these refusals apart
    // from the IndexError an unchecked read would throw (an ArgumentError).
    test('rejects a filterbank that is not nMels * nBins', () {
      final filters = loadMelFilterAsset('nemo_mel_80'); // 80 * 257
      expect(
        () => MelFilterSpans(filters, nMels: 80, nBins: 201),
        throwsStateError,
      );
      expect(
        () => MelFilterSpans(Float32List(0), nMels: 0, nBins: 257),
        throwsStateError,
      );
      expect(
        () => MelFilterSpans(filters, nMels: 80, nBins: 257),
        returnsNormally,
      );
    });

    test('apply rejects a wrong power length or output positions that do not '
        'fit, before writing anything', () {
      final spans = MelFilterSpans(
        loadMelFilterAsset('nemo_mel_80'),
        nMels: 80,
        nBins: 257,
      );
      final ones = Float32List(257)..fillRange(0, 257, 1.0);
      for (final (power, outLength, offset, stride) in [
        (Float32List(256), 80, 0, 1),
        (Float32List(258)..fillRange(0, 258, 1.0), 80, 0, 1),
        (ones, 79, 0, 1),
        (ones, 80, 1, 1),
        (ones, 80, -1, 1),
        (ones, 80, 0, 0),
      ]) {
        final out = Float32List(outLength)..fillRange(0, outLength, -1.0);
        expect(
          () => spans.apply(power, out, offset: offset, stride: stride),
          throwsStateError,
          reason: 'power ${power.length}, out $outLength, $offset/$stride',
        );
        expect(
          out.every((v) => v == -1.0),
          isTrue,
          reason: 'nothing written: power ${power.length}, out $outLength',
        );
      }
    });
  });

  group('window caches', () {
    test('hannWindowSymmetric is built once per length', () {
      final first = hannWindowSymmetric(400);
      expect(identical(hannWindowSymmetric(400), first), isTrue);
      expect(identical(hannWindowSymmetric(512), first), isFalse);
    });

    test('the cached hannWindowSymmetric is read-only', () {
      final window = hannWindowSymmetric(400);
      final before = window[200];
      expect(() => window[200] = 0, throwsUnsupportedError);
      expect(hannWindowSymmetric(400)[200], before);
    });

    test('applyHannWindow applies the periodic window', () {
      final frame = Float32List.fromList([
        for (var i = 0; i < 400; i++) (i % 7) - 3.0,
      ]);
      final first = applyHannWindow(frame);
      expect(applyHannWindow(frame), first);
      for (var i = 0; i < 400; i++) {
        final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / 400);
        expect(first[i], closeTo(frame[i] * w, 1e-6));
      }
    });
  });
}
