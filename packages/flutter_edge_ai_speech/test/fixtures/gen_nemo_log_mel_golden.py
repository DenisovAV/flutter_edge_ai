#!/usr/bin/env python3
"""Regenerate the NeMo/parakeet log-mel golden fixture.

INDEPENDENT reference for `computeNemoLogMel` (log_mel_frontend.dart): it
replicates NVIDIA/NeMo's `AudioToMelSpectrogramPreprocessor` recipe in numpy
(float64), and — the axis under test — computes the per-mel-bin z-score with
numpy's Bessel-corrected sample std (ddof=1), i.e. divide by N-1, matching real
NeMo's `normalize_batch` ("Subtract 1 in the denominator to correct for the
bias"). This is what de-circularises the golden: numpy's ddof=1 std is not
derived from the Dart hand-rolled std loop, so the fixture can now CATCH a
regression on the normalization convention instead of encoding the same
assumption as the code.

The Slaney mel filterbank is NOT re-derived here: it is decoded from the exact
bundled `nemo_mel_80.g.dart` matrix the Dart runtime uses, so this golden
isolates the z-score axis. The matrix is a `librosa.filters.mel(...)` output by
construction (see the .g.dart header); its correctness is out of scope for this
fixture, which exists to pin the ddof=1 normalization convention. Everything
else (tone, pre-emphasis, centered-window STFT, rfft power, ln) is standard
numpy, independent of the Dart implementation.

Usage:
    python3 test/fixtures/gen_nemo_log_mel_golden.py
Writes: test/fixtures/nemo_log_mel_golden_1s_440hz.json
Requires: numpy (no librosa — the filterbank comes from the bundled matrix).
"""
import base64
import json
import re
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
GDART = HERE.parent.parent / "lib/src/litert/mel_filters/nemo_mel_80.g.dart"
OUT = HERE / "nemo_log_mel_golden_1s_440hz.json"

# --- fixture parameters (must match the Dart test's read + tone regeneration) --
SAMPLE_RATE = 16000
SAMPLES = 16000  # 1 s
N_MELS = 80
N_FFT = 512
WIN_LENGTH = 400
HOP_LENGTH = 160
MEL_FRAMES = 100
PREEMPHASIS = 0.97
TONE_HZ = 440.0
TONE_AMPLITUDE = 0.1
LOG_ZERO_GUARD = 2.0 ** -24  # NeMo log_zero_guard_value
STD_FLOOR = 1e-5
N_BINS = N_FFT // 2 + 1  # 257


def load_bundled_mel_filters() -> np.ndarray:
    """Decode the exact bundled Slaney matrix ([n_mels, n_bins] float32 LE)."""
    text = GDART.read_text()
    # The generated file holds one long single-quoted base64 literal.
    m = re.search(r"'([A-Za-z0-9+/=]{1000,})'", text)
    if not m:
        raise SystemExit("could not find the base64 matrix in nemo_mel_80.g.dart")
    raw = base64.b64decode(m.group(1))
    mat = np.frombuffer(raw, dtype="<f4").astype(np.float64)
    if mat.size != N_MELS * N_BINS:
        raise SystemExit(f"matrix has {mat.size} floats, expected {N_MELS * N_BINS}")
    return mat.reshape(N_MELS, N_BINS)  # row-major [n_mels, n_bins]


def hann_symmetric(n: int) -> np.ndarray:
    # periodic=False Hann: 0.5 - 0.5*cos(2*pi*i/(n-1))  (== numpy.hanning(n))
    i = np.arange(n)
    return 0.5 - 0.5 * np.cos(2 * np.pi * i / (n - 1))


def main() -> None:
    mel_filters = load_bundled_mel_filters()

    # 1 s 440 Hz tone (same formula the Dart test regenerates from the fixture).
    i = np.arange(SAMPLES)
    pcm = TONE_AMPLITUDE * np.sin(2 * np.pi * TONE_HZ * i / SAMPLE_RATE)

    # Pre-emphasis: y[0]=x[0]; y[n]=x[n]-0.97*x[n-1].
    pre = pcm.copy()
    pre[1:] = pcm[1:] - PREEMPHASIS * pcm[:-1]

    # Centered window: symmetric Hann(win_length) zero-padded into the n_fft buffer.
    win = hann_symmetric(WIN_LENGTH)
    left = (N_FFT - WIN_LENGTH) // 2
    centered = np.zeros(N_FFT)
    centered[left:left + WIN_LENGTH] = win

    # Reflect-pad by n_fft//2 (numpy 'reflect' == Dart _reflectIndex).
    pad = N_FFT // 2
    padded = np.pad(pre, pad, mode="reflect")

    # STFT power spectrum per frame, then mel matmul -> ln.
    log_mel = np.empty((MEL_FRAMES, N_MELS))
    for f in range(MEL_FRAMES):
        base = f * HOP_LENGTH
        frame = padded[base:base + N_FFT] * centered
        power = np.abs(np.fft.rfft(frame, n=N_FFT)) ** 2  # [n_bins]
        mel = mel_filters @ power  # [n_mels]
        log_mel[f] = np.log(mel + LOG_ZERO_GUARD)

    # Per-mel-bin z-score over ALL frames, Bessel-corrected (ddof=1), floored.
    mean = log_mel.mean(axis=0)
    std = log_mel.std(axis=0, ddof=1)
    std = np.maximum(std, STD_FLOOR)
    normalized = (log_mel - mean) / std  # [mel_frames, n_mels] frame-first

    fixture = {
        "sampleRate": SAMPLE_RATE,
        "samples": SAMPLES,
        "nMels": N_MELS,
        "nFft": N_FFT,
        "winLength": WIN_LENGTH,
        "hopLength": HOP_LENGTH,
        "melFrames": MEL_FRAMES,
        "preemphasis": PREEMPHASIS,
        "toneHz": TONE_HZ,
        "toneAmplitude": TONE_AMPLITUDE,
        "frameFirstFlat": [float(v) for v in normalized.reshape(-1)],
    }
    OUT.write_text(json.dumps(fixture))
    print(f"wrote {OUT} ({normalized.size} values, ddof=1)")


if __name__ == "__main__":
    main()
