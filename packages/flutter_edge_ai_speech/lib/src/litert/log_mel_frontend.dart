// Pure-Dart, deterministic whisper-style log-mel spectrogram frontend. Every
// parameter (nFft, hopLength, nMels, melFrames) comes from the profile — this
// file has no whisper-specific constants, so a future log-mel family
// (parakeet) can reuse it with different sizes. `nFft=400` is not a power of
// two (400 = 2^4*5^2), so this uses a direct DFT rather than a radix-2 FFT —
// see docs/superpowers/notes/whisper-stt-spike-findings.md for the measured
// performance; swap to a mixed-radix/Bluestein FFT only if that is
// unacceptable (YAGNI per the design spec).
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Periodic Hann window of length [n] (matches `torch.hann_window(n)`'s
/// default `periodic=True`, the convention whisper's log-mel export uses):
/// `w[i] = 0.5 - 0.5*cos(2*pi*i/n)`.
Float32List applyHannWindow(Float32List frame) {
  final n = frame.length;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
    out[i] = frame[i] * w;
  }
  return out;
}

/// Direct DFT power spectrum `|X_k|^2` for `k` in `0..nFft/2` (the
/// non-redundant half of a real-input FFT, matching the mel filterbank's
/// `[nMels, nFft/2+1]` shape). O(nFft * nFft/2) per frame — acceptable at
/// whisper's `nFft=400`; see the file header for the FFT-swap escape hatch.
Float32List powerSpectrum(Float32List windowedFrame, int nFft) {
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

int _reflectIndex(int i, int n) {
  if (i < 0) return -i;
  if (i >= n) return 2 * (n - 1) - i;
  return i;
}

/// Reflect-pads [x] by [padAmount] samples on both sides (numpy/torch
/// 'reflect' mode: mirrors around the edge sample without repeating it).
/// Safe for a single reflection as long as `padAmount < x.length`, which
/// holds for every profile this frontend supports (`nFft/2=200 << 480000`).
Float32List _reflectPad(Float32List x, int padAmount) {
  final n = x.length;
  final out = Float32List(n + 2 * padAmount);
  for (var i = -padAmount; i < n + padAmount; i++) {
    out[i + padAmount] = x[_reflectIndex(i, n)];
  }
  return out;
}

/// Frame [paddedPcm] into exactly [melFrames] Hann-windowed windows of
/// length [nFft], hopping by [hopLength], center-aligned via reflect
/// padding of `nFft~/2` on both sides (matches `torch.stft(..., center=
/// True)`, which whisper's log-mel export uses). `torch.stft` yields
/// `1 + paddedPcm.length/hopLength` frames; whisper's export drops the
/// LAST one (`stft[..., :-1]`) to land exactly on [melFrames] — this
/// function returns only the kept [melFrames], already windowed.
List<Float32List> stftFrames(
  Float32List paddedPcm, {
  required int nFft,
  required int hopLength,
  required int melFrames,
}) {
  final padded = _reflectPad(paddedPcm, nFft ~/ 2);
  final frames = <Float32List>[];
  for (var f = 0; f < melFrames; f++) {
    final base = f * hopLength;
    final raw = Float32List.sublistView(padded, base, base + nFft);
    frames.add(applyHannWindow(raw));
  }
  return frames;
}

/// Whisper's log/normalize step: `log10(max(mel,1e-10))`, floor at
/// `max-8`, then `(x+4)/4`. `SttMelNormalization.none` is a passthrough
/// (reserved for a future family that needs no normalization).
Float32List _applyNormalization(
  Float32List mel,
  SttMelNormalization normalization,
) {
  switch (normalization) {
    case SttMelNormalization.none:
      return mel;
    case SttMelNormalization.nemo:
      // NeMo's per-mel-bin z-score is applied inline by computeNemoLogMel,
      // never here. Reaching this means a profile was misconfigured to run the
      // whisper-style frontend with nemo normalization — fail loud rather than
      // silently applying whisper's log10 affine (which would produce a
      // plausible-but-wrong spectrogram).
      throw ArgumentError(
        'SttMelNormalization.nemo must be applied via computeNemoLogMel, not '
        'the whisper log-mel frontend (computeLogMelSpectrogram).',
      );
    case SttMelNormalization.whisper:
      break; // whisper log10 path below
  }
  final log10Mel = Float32List(mel.length);
  var maxLog = double.negativeInfinity;
  for (var i = 0; i < mel.length; i++) {
    final clamped = mel[i] < 1e-10 ? 1e-10 : mel[i];
    final v = math.log(clamped) / math.ln10;
    log10Mel[i] = v;
    if (v > maxLog) maxLog = v;
  }
  final floor = maxLog - 8.0;
  for (var i = 0; i < log10Mel.length; i++) {
    final v = log10Mel[i] < floor ? floor : log10Mel[i];
    log10Mel[i] = (v + 4.0) / 4.0;
  }
  return log10Mel;
}

/// Full log-mel pipeline: STFT (via [stftFrames]) -> power spectrum ->
/// mel filterbank matmul -> normalize. Returns row-major `[nMels,
/// melFrames]` (melFirst — whisper's `[1,80,3000]` encoder input layout).
/// Every size comes from the caller (the profile), not a whisper constant.
Float32List computeLogMelSpectrogram(
  Float32List paddedPcm, {
  required int nFft,
  required int hopLength,
  required int nMels,
  required int melFrames,
  required Float32List melFilters,
  required SttMelNormalization normalization,
}) {
  final nBins = nFft ~/ 2 + 1;
  final frames = stftFrames(
    paddedPcm,
    nFft: nFft,
    hopLength: hopLength,
    melFrames: melFrames,
  );

  final power = Float32List(melFrames * nBins); // [frame, bin]
  for (var f = 0; f < melFrames; f++) {
    final p = powerSpectrum(frames[f], nFft);
    power.setRange(f * nBins, f * nBins + nBins, p);
  }

  final mel = Float32List(nMels * melFrames); // [mel, frame] (melFirst)
  for (var m = 0; m < nMels; m++) {
    final filterBase = m * nBins;
    for (var f = 0; f < melFrames; f++) {
      var sum = 0.0;
      final frameBase = f * nBins;
      for (var b = 0; b < nBins; b++) {
        sum += melFilters[filterBase + b] * power[frameBase + b];
      }
      mel[m * melFrames + f] = sum;
    }
  }

  return _applyNormalization(mel, normalization);
}

/// Symmetric (periodic=False) Hann window of length [n]: `w[i] = 0.5 -
/// 0.5*cos(2*pi*i/(n-1))` -- matches `numpy.hanning(n)` /
/// `torch.hann_window(n, periodic=False)`. Distinct from [applyHannWindow]
/// (whisper's periodic=True convention, `.../n` not `.../(n-1)`) -- NeMo/
/// parakeet's frontend uses this symmetric variant.
Float32List hannWindowSymmetric(int n) {
  final w = Float32List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
  }
  return w;
}

/// Pre-emphasis `y[n] = x[n] - preemphasis*x[n-1]` (`y[0] = x[0]`, i.e. an
/// implicit `x[-1] = 0`) -- NeMo's `AudioToMelSpectrogramPreprocessor`
/// default `preemph=0.97`. Applied to the RAW pcm, before reflect-padding
/// or framing.
Float32List applyPreemphasis(Float32List x, double preemphasis) {
  final y = Float32List(x.length);
  if (x.isEmpty) return y;
  y[0] = x[0];
  for (var n = 1; n < x.length; n++) {
    y[n] = x[n] - preemphasis * x[n - 1];
  }
  return y;
}

/// Centers [window] (length `<= nFft`) into a zero-padded buffer of length
/// [nFft]: `(nFft - window.length) ~/ 2` zeros on each side -- NeMo/
/// `torch.stft`'s `win_length < n_fft` convention (whisper's `win_length ==
/// n_fft`, so it never needs this).
Float32List centerWindowInBuffer(Float32List window, int nFft) {
  final left = (nFft - window.length) ~/ 2;
  final out = Float32List(nFft);
  out.setRange(left, left + window.length, window);
  return out;
}

/// Frame [paddedPcm] (ALREADY preemphasized) into exactly [melFrames]
/// nFft-length windows, hopping by [hopLength], center-aligned via
/// reflect-padding of `nFft~/2` on both sides (same centering convention as
/// [stftFrames]) -- but each frame is multiplied by [centeredWindow] (see
/// [centerWindowInBuffer]), a `winLength`-sample window zero-padded to
/// `nFft` samples, rather than a window covering the whole frame. This is
/// NeMo/parakeet's `win_length != n_fft` STFT convention.
List<Float32List> nemoStftFrames(
  Float32List paddedPcm, {
  required int nFft,
  required int hopLength,
  required int melFrames,
  required Float32List centeredWindow,
}) {
  final padded = _reflectPad(paddedPcm, nFft ~/ 2);
  final frames = <Float32List>[];
  for (var f = 0; f < melFrames; f++) {
    final base = f * hopLength;
    final raw = Float32List.sublistView(padded, base, base + nFft);
    final windowed = Float32List(nFft);
    for (var i = 0; i < nFft; i++) {
      windowed[i] = raw[i] * centeredWindow[i];
    }
    frames.add(windowed);
  }
  return frames;
}

/// Full NeMo/parakeet log-mel pipeline: preemphasis -> centered-window STFT
/// (via [nemoStftFrames]) -> power spectrum -> Slaney mel filterbank matmul
/// -> natural log (`ln(mel + 2^-24)`) -> FULL-WINDOW per-mel-bin z-score
/// (mean/std computed over ALL [melFrames], including any silence padding
/// -- NOT masked to the valid-audio length; see the design spec's Risk #5.
/// The masked/valid-length variant is a documented follow-on). Returns
/// row-major `[melFrames, nMels]` (FRAME-FIRST -- opposite layout from
/// [computeLogMelSpectrogram]'s melFirst, per parakeet's `[1,500,80]`
/// encoder input contract).
Float32List computeNemoLogMel(
  Float32List paddedPcm, {
  required int nFft,
  required int winLength,
  required int hopLength,
  required double preemphasis,
  required int nMels,
  required int melFrames,
  required Float32List melFilters,
}) {
  final nBins = nFft ~/ 2 + 1;
  final pre = applyPreemphasis(paddedPcm, preemphasis);
  final centeredWindow = centerWindowInBuffer(
    hannWindowSymmetric(winLength),
    nFft,
  );
  final frames = nemoStftFrames(
    pre,
    nFft: nFft,
    hopLength: hopLength,
    melFrames: melFrames,
    centeredWindow: centeredWindow,
  );

  final mel = Float32List(melFrames * nMels); // [frame, mel] (frameFirst)
  for (var f = 0; f < melFrames; f++) {
    final power = powerSpectrum(frames[f], nFft);
    for (var m = 0; m < nMels; m++) {
      final filterBase = m * nBins;
      var sum = 0.0;
      for (var b = 0; b < nBins; b++) {
        sum += melFilters[filterBase + b] * power[b];
      }
      mel[f * nMels + m] = sum;
    }
  }

  const logZeroGuard = 1.0 / 16777216.0; // 2^-24, NeMo's log_zero_guard_value
  final logMel = Float32List(mel.length);
  for (var i = 0; i < mel.length; i++) {
    logMel[i] = math.log(mel[i] + logZeroGuard);
  }

  // Full-window per-mel-bin z-score: mean/std over ALL melFrames (including
  // silence padding), floored at 1e-5.
  //
  // Uses the Bessel-corrected SAMPLE std (ddof=1, divide by N-1) — matching
  // NVIDIA/NeMo's `normalize_batch`, whose source literally comments "Subtract
  // 1 in the denominator to correct for the bias". The committed golden fixture
  // is regenerated with the SAME ddof=1 by an INDEPENDENT numpy reference
  // (test/fixtures/gen_nemo_log_mel_golden.py — it reuses the bundled Slaney
  // matrix but computes the z-score via numpy's own std), so the golden test
  // genuinely verifies this convention instead of encoding it. The N vs N-1
  // choice is a uniform sqrt(N/(N-1)) per-bin scale (~0.1% at melFrames=500),
  // so it never flips a per-frame CTC argmax — but ddof=1 is the correct
  // reference algorithm. `math.max(1, melFrames - 1)` guards the degenerate
  // single-frame case (ddof=1 is undefined for N=1); production melFrames is
  // 100/500.
  final mean = Float64List(nMels);
  for (var f = 0; f < melFrames; f++) {
    for (var m = 0; m < nMels; m++) {
      mean[m] += logMel[f * nMels + m];
    }
  }
  for (var m = 0; m < nMels; m++) {
    mean[m] /= melFrames;
  }
  final std = Float64List(nMels);
  for (var f = 0; f < melFrames; f++) {
    for (var m = 0; m < nMels; m++) {
      final d = logMel[f * nMels + m] - mean[m];
      std[m] += d * d;
    }
  }
  final ddofDenom = math.max(1, melFrames - 1);
  for (var m = 0; m < nMels; m++) {
    final s = math.sqrt(std[m] / ddofDenom);
    std[m] = s < 1e-5 ? 1e-5 : s;
  }

  final normalized = Float32List(mel.length);
  for (var f = 0; f < melFrames; f++) {
    for (var m = 0; m < nMels; m++) {
      final idx = f * nMels + m;
      normalized[idx] = (logMel[idx] - mean[m]) / std[m];
    }
  }
  return normalized;
}

/// How a profile's log-mel output is normalized (see [computeLogMelSpectrogram]).
enum SttMelNormalization { none, whisper, nemo }
