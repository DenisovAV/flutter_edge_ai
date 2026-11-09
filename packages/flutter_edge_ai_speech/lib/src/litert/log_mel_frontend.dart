// Pure-Dart, deterministic log-mel spectrogram frontend. Every parameter
// (nFft, hopLength, nMels, melFrames) comes from the profile — this file has
// no whisper-specific constants, so the NeMo/parakeet family reuses it with
// different sizes.
//
// `nFft=400` (whisper) is not a power of two (400 = 2^4*5^2), so the transform
// is a Bluestein chirp-z FFT over a radix-2 kernel: `M = nextPow2(2*nFft - 1)`
// is always a power of two, so one code path serves every nFft this frontend
// is asked for, with no mixed-radix special cases (#784). A direct DFT used to
// run here; measured on linux_x64 with Dart AOT (release), whisper's 3000-frame
// window spent 5.2-5.6 s of its frontend in it — RTF 0.18, i.e. the spectrogram
// alone cost 18% of the audio's own duration — and it is paid on every turn
// because the profile zero-pads to a fixed 30 s window. See `powerSpectrum`'s
// doc comment for the after numbers. The direct DFT now lives on only as the
// oracle in test/log_mel_frontend_test.dart, which holds the FFT to it for
// nFft in {400, 512}.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Periodic Hann window of length [n] (matches `torch.hann_window(n)`'s
/// default `periodic=True`, the convention whisper's log-mel export uses):
/// `w[i] = 0.5 - 0.5*cos(2*pi*i/n)`.
///
/// The window is identical for every frame of a clip, so it is built once per
/// length and cached: whisper's 3000 frames used to evaluate 1.2M cosines here.
/// The returned list is shared — callers must not mutate it.
Float32List _periodicHann(int n) => _periodicHannWindows.putIfAbsent(n, () {
  final w = Float32List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
  }
  return w;
});

final _periodicHannWindows = <int, Float32List>{};

/// Multiplies [frame] by the periodic Hann window of its own length. The
/// window comes from [_periodicHann], so this costs one multiply per sample.
Float32List applyHannWindow(Float32List frame) {
  final n = frame.length;
  final window = _periodicHann(n);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = frame[i] * window[i];
  }
  return out;
}

/// Power spectrum `|X_k|^2` for `k` in `0..nFft/2` (the non-redundant half of
/// a real-input FFT, matching the mel filterbank's `[nMels, nFft/2+1]` shape),
/// computed as a Bluestein chirp-z FFT: `X_k = w_k * (a * b)_k` with
/// `a_t = x_t * w_t`, `b_j = conj(w_j)` and `w_j = exp(-i*pi*j^2/nFft)`, where
/// the convolution is the cyclic one over `M = nextPow2(2*nFft - 1)` — large
/// enough that it equals the linear convolution.
///
/// The plan (chirp, kernel FFT, twiddles) is built once per `nFft`; a frame
/// costs two radix-2 FFTs of length `M` instead of `nFft * nBins` cos/sin
/// pairs. Measured on linux_x64 with Dart AOT (release), a whole whisper window
/// (3000 frames, nFft=400) went from 5.2-5.6 s to 134-166 ms (about 35x);
/// parakeet (500 frames, nFft=512) from 1.4-1.6 s to 23-29 ms (about 58x).
Float32List powerSpectrum(Float32List windowedFrame, int nFft) {
  final plan = _bluesteinPlanFor(nFft);
  final m = plan.m;
  final re = plan.scratchRe;
  final im = plan.scratchIm;
  for (var i = 0; i < nFft; i++) {
    final x = windowedFrame[i];
    re[i] = x * plan.chirpRe[i];
    im[i] = x * plan.chirpIm[i];
  }
  re.fillRange(nFft, m, 0.0);
  im.fillRange(nFft, m, 0.0);

  _radix2Fft(re, im, m, plan.twiddleCos, plan.twiddleSin, inverse: false);
  for (var i = 0; i < m; i++) {
    final ar = re[i], ai = im[i];
    final br = plan.kernelRe[i], bi = plan.kernelIm[i];
    re[i] = ar * br - ai * bi;
    im[i] = ar * bi + ai * br;
  }
  _radix2Fft(re, im, m, plan.twiddleCos, plan.twiddleSin, inverse: true);

  final power = Float32List(plan.nBins);
  final scale = 1.0 / m;
  for (var k = 0; k < plan.nBins; k++) {
    final cr = re[k] * scale, ci = im[k] * scale;
    final xr = cr * plan.chirpRe[k] - ci * plan.chirpIm[k];
    final xi = cr * plan.chirpIm[k] + ci * plan.chirpRe[k];
    power[k] = xr * xr + xi * xi;
  }
  return power;
}

int _nextPowerOfTwo(int value) {
  var power = 1;
  while (power < value) {
    power <<= 1;
  }
  return power;
}

/// Iterative radix-2 Cooley-Tukey FFT over a precomputed twiddle table of
/// `n/2` entries. [inverse] conjugates the twiddles; the `1/n` scale is the
/// caller's.
void _radix2Fft(
  Float64List re,
  Float64List im,
  int n,
  Float64List twiddleCos,
  Float64List twiddleSin, {
  required bool inverse,
}) {
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final half = len >> 1;
    final step = n ~/ len;
    for (var base = 0; base < n; base += len) {
      for (var j = 0; j < half; j++) {
        final wr = twiddleCos[j * step];
        final ws = twiddleSin[j * step];
        final wi = inverse ? ws : -ws;
        final ar = re[base + j + half], ai = im[base + j + half];
        final tr = ar * wr - ai * wi;
        final ti = ar * wi + ai * wr;
        final ur = re[base + j], ui = im[base + j];
        re[base + j] = ur + tr;
        im[base + j] = ui + ti;
        re[base + j + half] = ur - tr;
        im[base + j + half] = ui - ti;
      }
    }
  }
}

/// One nFft's Bluestein plan, built once and reused by every frame: the chirp,
/// the kernel's FFT and the twiddles are all `O(M log M)`, so rebuilding them
/// per frame would cost more than the transform they feed.
///
/// [scratchRe]/[scratchIm] are shared by every [powerSpectrum] call. That is
/// safe because the frontend is synchronous — a clip never interleaves its own
/// frames — and an isolate holds its own copy of these statics.
final class _BluesteinPlan {
  _BluesteinPlan(int nFft) : this._(nFft, _nextPowerOfTwo(2 * nFft - 1));

  _BluesteinPlan._(int nFft, this.m)
    : nBins = nFft ~/ 2 + 1,
      chirpRe = Float64List(2 * nFft - 1),
      chirpIm = Float64List(2 * nFft - 1),
      kernelRe = Float64List(m),
      kernelIm = Float64List(m),
      twiddleCos = Float64List(m ~/ 2),
      twiddleSin = Float64List(m ~/ 2),
      scratchRe = Float64List(m),
      scratchIm = Float64List(m) {
    // w_i = exp(-i*pi*i^2/nFft). i^2 is reduced modulo 2*nFft first: the angle
    // has that period, and the raw square would lose precision for large i.
    for (var i = 0; i < 2 * nFft - 1; i++) {
      final angle = -math.pi * ((i * i) % (2 * nFft)) / nFft;
      chirpRe[i] = math.cos(angle);
      chirpIm[i] = math.sin(angle);
    }
    for (var i = 0; i < m ~/ 2; i++) {
      final angle = -2 * math.pi * i / m;
      twiddleCos[i] = math.cos(angle);
      twiddleSin[i] = math.sin(angle);
    }
    // b_j = conj(w_j), mirrored around 0 so the cyclic convolution over M is
    // the linear one: b[j] and b[M-j] carry the same value for j in 1..n-1.
    for (var j = 0; j < nFft; j++) {
      kernelRe[j] = chirpRe[j];
      kernelIm[j] = -chirpIm[j];
      if (j > 0) {
        kernelRe[m - j] = chirpRe[j];
        kernelIm[m - j] = -chirpIm[j];
      }
    }
    _radix2Fft(kernelRe, kernelIm, m, twiddleCos, twiddleSin, inverse: false);
  }

  final int m;
  final int nBins;
  final Float64List chirpRe;
  final Float64List chirpIm;
  final Float64List kernelRe;
  final Float64List kernelIm;
  final Float64List twiddleCos;
  final Float64List twiddleSin;
  final Float64List scratchRe;
  final Float64List scratchIm;
}

/// Plans are keyed by `nFft`; a process asks for one or two sizes (whisper's
/// 400, parakeet's 512), so this holds a couple of entries at most.
final _bluesteinPlans = <int, _BluesteinPlan>{};

_BluesteinPlan _bluesteinPlanFor(int nFft) =>
    _bluesteinPlans.putIfAbsent(nFft, () => _BluesteinPlan(nFft));

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

/// Every mel filter's non-zero span, extracted once per frontend call.
///
/// The bundled filterbanks are ~2.4% dense — 391 of 80*201 entries for whisper,
/// 500 of 80*257 for NeMo — and each triangular filter's non-zeros are
/// contiguous. Summing only inside the span therefore drops ~97% of the
/// multiplies. The skipped terms are exactly `0.0 * power`, and adding 0.0 does
/// not change a running sum, while the surviving terms keep their
/// left-to-right order: [apply] is bit-identical to the dense `nBins` loop.
final class MelFilterSpans {
  MelFilterSpans(
    Float32List melFilters, {
    required this.nMels,
    required int nBins,
  }) : _starts = Int32List(nMels),
       _offsets = Int32List(nMels + 1) {
    final coefficients = <double>[];
    for (var m = 0; m < nMels; m++) {
      final base = m * nBins;
      var first = 0;
      while (first < nBins && melFilters[base + first] == 0.0) {
        first++;
      }
      if (first == nBins) {
        // An all-zero filter row contributes 0.0 and leaves the sum at 0.0.
        _starts[m] = 0;
        _offsets[m + 1] = coefficients.length;
        continue;
      }
      var last = nBins - 1;
      while (last > first && melFilters[base + last] == 0.0) {
        last--;
      }
      _starts[m] = first;
      for (var b = first; b <= last; b++) {
        coefficients.add(melFilters[base + b]);
      }
      _offsets[m + 1] = coefficients.length;
    }
    _coefficients = Float32List.fromList(coefficients);
  }

  final int nMels;
  final Int32List _starts;
  final Int32List _offsets;
  late final Float32List _coefficients;

  /// Number of multiplies [apply] performs for one frame.
  int get multiplicationCount => _coefficients.length;

  /// Writes `sum_b melFilters[m][b] * power[b]` for every `m` into
  /// `out[offset + m * stride]`.
  void apply(
    Float32List power,
    Float32List out, {
    int offset = 0,
    int stride = 1,
  }) {
    for (var m = 0; m < nMels; m++) {
      final coefficientsEnd = _offsets[m + 1];
      var coefficient = _offsets[m];
      var bin = _starts[m];
      var sum = 0.0;
      for (; coefficient < coefficientsEnd; coefficient++, bin++) {
        sum += _coefficients[coefficient] * power[bin];
      }
      out[offset + m * stride] = sum;
    }
  }
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

  final spans = MelFilterSpans(melFilters, nMels: nMels, nBins: nBins);
  final mel = Float32List(nMels * melFrames); // [mel, frame] (melFirst)
  for (var f = 0; f < melFrames; f++) {
    spans.apply(
      powerSpectrum(frames[f], nFft),
      mel,
      offset: f,
      stride: melFrames,
    );
  }

  return _applyNormalization(mel, normalization);
}

/// Symmetric (periodic=False) Hann window of length [n]: `w[i] = 0.5 -
/// 0.5*cos(2*pi*i/(n-1))` -- matches `numpy.hanning(n)` /
/// `torch.hann_window(n, periodic=False)`. Distinct from [applyHannWindow]
/// (whisper's periodic=True convention, `.../n` not `.../(n-1)`) -- NeMo/
/// parakeet's frontend uses this symmetric variant.
///
/// Built once per [n] and cached across calls. The returned list is shared —
/// callers must not mutate it (NeMo's caller only copies it into the
/// zero-padded buffer via [centerWindowInBuffer]).
Float32List hannWindowSymmetric(int n) =>
    _symmetricHannWindows.putIfAbsent(n, () {
      final w = Float32List(n);
      for (var i = 0; i < n; i++) {
        w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
      }
      return w;
    });

final _symmetricHannWindows = <int, Float32List>{};

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

  final spans = MelFilterSpans(melFilters, nMels: nMels, nBins: nBins);
  final mel = Float32List(melFrames * nMels); // [frame, mel] (frameFirst)
  for (var f = 0; f < melFrames; f++) {
    spans.apply(powerSpectrum(frames[f], nFft), mel, offset: f * nMels);
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
