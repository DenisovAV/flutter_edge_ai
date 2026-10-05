import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/registry/runtime_config.dart'
    show ActiveEmbedderParams;
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Said once per isolate. The parameter is passed on every call or on none, so
/// repeating it per embedder would only drown the console — and a caller who
/// needs the value rather than a message reads
/// `EmbeddingModel.activeBackend`, which survives a release build.
///
/// Per-isolate, not per-process: a top-level mutable gets its own copy in a
/// spawned isolate (see the note in `gemma_log.dart`). The shells call this on
/// the isolate that owns the singleton, so in practice it is said once.
bool _warned = false;

/// Says out loud that `getActiveEmbedder(preferredBackend:)` did not reach the
/// embedder, from ONE place that every shell calls.
///
/// It lives here rather than in a backend because a backend cannot see the
/// singleton cache: the shells serve a second `getActiveEmbedder` from the
/// cached instance without calling `createModel` at all, so a notice inside a
/// backend is unreachable in the most ordinary sequence — build an embedder,
/// then ask for one with a backend.
///
/// CPU is not a fallback here and this is not a warning about degradation: it
/// is the only correct answer, because LiteRT's GPU delegate returns all-zero
/// vectors for EmbeddingGemma's int4 weights and the ONNX client appends no
/// execution provider. What was wrong was accepting the argument in silence.
void noticeEmbedderBackendIgnored(PreferredBackend? requested) {
  if (!ActiveEmbedderParams.isIgnoredBackend(requested) || _warned) return;
  // Spend the one shot only on a line that can actually appear. `gemmaLog`
  // returns early in a release build and when the level is `none`, and the
  // level is public API — so setting the flag first turned "say it once" into
  // "suppress once" for an app that starts silent and raises the level later
  // to debug exactly this.
  if (!kDebugMode || gemmaLogLevel == GemmaLogLevel.none) return;
  _warned = true;
  gemmaLog(
    'ℹ️  Embeddings run on CPU: preferredBackend ${requested!.name} is not '
    'applied. Read EmbeddingModel.activeBackend for the backend in use — it '
    'is available in release builds, where this line is not.',
  );
}

/// The web counterpart of [noticeEmbedderBackendIgnored], with a different
/// rule as well as different words.
///
/// On web NO value of `preferredBackend` reaches an embedder — `cpu`
/// included, which the native rule rightly stays quiet about because native
/// embeddings do run on CPU. Here the runtime chooses: LiteRT.js asks for
/// WebGPU and falls back to WASM, and onnxruntime-web tries `webgpu` then
/// `wasm`. The native line said "Embeddings run on CPU" to a caller whose
/// embeddings were running on WebGPU — a backend reported that did not run.
void noticeWebEmbedderBackendIgnored(PreferredBackend? requested) {
  if (requested == null || _warned) return;
  if (!kDebugMode || gemmaLogLevel == GemmaLogLevel.none) return;
  _warned = true;
  gemmaLog(
    'ℹ️  preferredBackend ${requested.name} is not applied to embeddings on '
    'web: the runtime picks the accelerator (WebGPU first, WASM as the '
    'fallback). EmbeddingModel.activeBackend is null on web; with LiteRT, '
    'window.getLiteRtEmbeddingAccelerator() names it after the first '
    'embedding.',
  );
}

/// Lets a test assert from a known state. The flag is private and per-isolate
/// otherwise, which is what forces one test to carry every case in order.
@visibleForTesting
void resetEmbedderBackendNotice() => _warned = false;
