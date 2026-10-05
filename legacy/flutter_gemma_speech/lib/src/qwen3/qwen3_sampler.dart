// Sampler + cb0 scoring for the Qwen3-TTS talker's per-frame codebook-0
// (cb0) token pick.
//
// Ports `Qwen3TtsPipeline._pick` (the recipe's `qwen3_tts_pipeline.py` —
// see `qwen3_tts_core.dart`'s file header for where it's vendored and why
// citations below name Python symbols, not line numbers) and the per-step
// scoring edits applied before it in `Qwen3TtsPipeline.synthesize`
// (`suppress`, the min-new-tokens guard, and the HF repetition penalty)
// verbatim.
//
// This file is pure Dart (`dart:math` / `dart:typed_data` only) — no
// Flutter import — so it can be unit-tested without a device and needs no
// model tables (all inputs are hand-constructable vectors).

import 'dart:math';
import 'dart:typed_data';

/// Talker codec-token vocabulary size. qwen3_tts_pipeline.py _CODEC_VOCAB.
const int _codecVocab = 3072;

/// Codec end-of-sequence token id. qwen3_tts_pipeline.py _CODEC_EOS.
const int _codecEos = 2150;

/// Large negative "suppressed" score, added to logits to rule a token out
/// of the argmax/sampling pick without producing `-inf` arithmetic hazards.
/// qwen3_tts_pipeline.py _NEG_INF.
const double _negInf = -1e9;

/// Builds the per-step control-token suppression vector.
///
/// Every codec-vocabulary index `>= 2048` is a control/special token (only
/// `< 2048` are audible codebook-0 codes), so those are suppressed by
/// `_negInf` — except [_codecEos], which is always a legal pick (the talker
/// must be able to end the utterance). Ports
/// `qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize` verbatim:
/// ```python
/// suppress = np.zeros(_CODEC_VOCAB, np.float32)
/// suppress[2048:] = _NEG_INF
/// suppress[_CODEC_EOS] = 0.0
/// ```
Float32List buildSuppress() {
  final suppress = Float32List(_codecVocab);
  for (var i = 2048; i < _codecVocab; i++) {
    suppress[i] = _negInf;
  }
  suppress[_codecEos] = 0.0;
  return suppress;
}

/// Applies the talker's per-step cb0 scoring edits to [scores] **in
/// place** (matches the recipe, which reassigns entries of the `scores`
/// array directly rather than returning a new one — callers must pass an
/// array that is safe to mutate, e.g. a fresh copy of the raw logits, since
/// the original logits are still needed elsewhere in the decode loop).
///
/// Ports `qwen3_tts_pipeline.py Qwen3TtsPipeline.synthesize` verbatim:
/// ```python
/// scores = logits + suppress
/// if len(frames) < 2:  # min_new_tokens=2
///     scores[_CODEC_EOS] = _NEG_INF
/// for token in history:
///     scores[token] = (scores[token] / repetition_penalty
///                      if scores[token] > 0
///                      else scores[token] * repetition_penalty)
/// ```
/// [minNewTokensGuard] is the caller-evaluated `len(frames) < 2` condition
/// (frame-count bookkeeping lives in the decode loop, `synthesize` — this
/// function only applies the resulting edit).
void applyCb0Scoring(
  Float32List scores, {
  required Float32List suppress,
  required Set<int> history,
  required double repetitionPenalty,
  required bool minNewTokensGuard,
}) {
  for (var i = 0; i < scores.length; i++) {
    scores[i] += suppress[i];
  }
  if (minNewTokensGuard) {
    scores[_codecEos] = _negInf;
  }
  for (final token in history) {
    final s = scores[token];
    scores[token] = s > 0 ? s / repetitionPenalty : s * repetitionPenalty;
  }
}

/// Deterministic, RNG-free pick: the argmax index of [logits].
///
/// This is the golden-decode path (`do_sample=False` in the recipe):
/// `return int(np.argmax(logits))` (`qwen3_tts_pipeline.py _pick`). Matches
/// numpy's `argmax` tie-break — the **first** (lowest-index) maximum wins.
int pickGreedy(Float32List logits) {
  if (logits.isEmpty) {
    throw ArgumentError.value(
      logits.length,
      'logits.length',
      'pickGreedy: logits must not be empty',
    );
  }
  var bestIndex = 0;
  var bestValue = logits[0];
  for (var i = 1; i < logits.length; i++) {
    if (logits[i] > bestValue) {
      bestValue = logits[i];
      bestIndex = i;
    }
  }
  return bestIndex;
}

/// Top-k / temperature sampling pick (production quality — not the golden
/// gate, which uses [pickGreedy]).
///
/// Ports `qwen3_tts_pipeline.py _pick`'s sampling branch:
/// ```python
/// scaled = logits.astype(np.float64) / max(temperature, 1e-6)
/// if top_k and top_k < len(scaled):
///     kth = np.partition(scaled, -top_k)[-top_k]
///     scaled = np.where(scaled < kth, -np.inf, scaled)
/// scaled -= scaled.max()
/// probs = np.exp(scaled)
/// probs /= probs.sum()
/// return int(rng.choice(len(probs), p=probs))
/// ```
/// Computed in `double` precision throughout (matching the recipe's
/// `.astype(np.float64)`), returning an `int`. The final draw is a plain
/// cumulative-sum inverse-CDF sample from [rng] (a `dart:math.Random`) —
/// this does not attempt to bit-reproduce numpy `Generator.choice`'s
/// internal algorithm; determinism is only required (and tested) against a
/// seeded Dart [Random].
int pickSampled(
  Float32List logits, {
  required int topK,
  required double temperature,
  required Random rng,
}) {
  if (logits.isEmpty) {
    throw ArgumentError.value(
      logits.length,
      'logits.length',
      'pickSampled: logits must not be empty',
    );
  }
  final n = logits.length;
  final denom = max(temperature, 1e-6);
  final scaled = List<double>.generate(n, (i) => logits[i] / denom);

  if (topK > 0 && topK < n) {
    // np.partition(scaled, -top_k)[-top_k]: the value that would land at
    // index `n - top_k` in a fully sorted-ascending array, i.e. the
    // top_k-th largest value — the keep/suppress threshold. Ties at the
    // threshold are all kept (matches `scaled < kth`, not a rank cutoff),
    // so more than top_k entries may survive when the threshold value
    // repeats.
    final sortedDesc = List<double>.of(scaled)..sort((a, b) => b.compareTo(a));
    final kth = sortedDesc[topK - 1];
    for (var i = 0; i < n; i++) {
      if (scaled[i] < kth) scaled[i] = double.negativeInfinity;
    }
  }

  var maxVal = scaled[0];
  for (var i = 1; i < n; i++) {
    if (scaled[i] > maxVal) maxVal = scaled[i];
  }
  var sum = 0.0;
  final probs = List<double>.generate(n, (i) {
    final p = exp(scaled[i] - maxVal);
    sum += p;
    return p;
  });
  for (var i = 0; i < n; i++) {
    probs[i] /= sum;
  }

  // Cumulative-sum inverse-CDF sample.
  final u = rng.nextDouble();
  var cumulative = 0.0;
  for (var i = 0; i < n; i++) {
    cumulative += probs[i];
    if (u < cumulative) return i;
  }
  return n - 1; // Guards float round-off so the draw never falls through.
}
