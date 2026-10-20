import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/src/registry/runtime_config.dart'
    show ActiveEmbedderParams;
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';

/// Said once per isolate. The parameter is passed on every call or on none, so
/// repeating it per embedder would only drown the console — and a caller who
/// needs the value rather than a message reads
/// `EmbeddingModel.activeBackend`, which survives a release build.
///
/// Per-isolate, not per-process: a top-level mutable gets its own copy in a
/// spawned isolate (see the note in `edge_ai_log.dart`). The shells call this on
/// the isolate that owns the singleton, so in practice it is said once.
bool _warned = false;

/// Says once that a legacy CPU-only provider ignores a GPU request.
/// Accelerator-aware providers use [noticeEmbedderBackendFallback] after load.
/// LiteRT's int4 GPU delegate returns all-zero vectors; native ONNX uses CPU.
void noticeEmbedderBackendIgnored(PreferredBackend? requested) {
  if (!ActiveEmbedderParams.isIgnoredBackend(requested) || _warned) return;
  // Spend the one shot only on a line that can actually appear. `gemmaLog`
  // returns early in a release build and when the level is `none`, and the
  // level is public API — so setting the flag first turned "say it once" into
  // "suppress once" for an app that starts silent and raises the level later
  // to debug exactly this.
  if (!kDebugMode || edgeAiLogLevel == EdgeAiLogLevel.none) return;
  _warned = true;
  edgeAiLog(
    'ℹ️  Embeddings run on CPU: preferredBackend ${requested!.name} is not '
    'applied. Read EmbeddingModel.activeBackend for the backend in use — it '
    'is available in release builds, where this line is not.',
  );
}

/// Says once that `getActiveEmbedder(preferredBackend: npu)` returned an
/// embedder that does not run on the NPU — a `.tflite` or ONNX embedder, which
/// have no NPU path and run on CPU as before. Called by the loader with the
/// model it returns (built or reused), because only the backend knows whether
/// it honoured the request. An EmbeddingGemma 2 `.litertlm` bundle never gets
/// here: the LiteRT-LM backend runs a per-SoC bundle on the NPU or refuses.
void noticeEmbedderNpuNotApplied(
  PreferredBackend? requested,
  PreferredBackend? active,
) {
  if (requested != PreferredBackend.npu ||
      active == PreferredBackend.npu ||
      _warned) {
    return;
  }
  if (!kDebugMode || edgeAiLogLevel == EdgeAiLogLevel.none) return;
  _warned = true;
  edgeAiLog(
    'ℹ️  preferredBackend npu is not applied: this embedder runs on '
    '${active?.name ?? 'the accelerator its runtime picks'}. Only '
    'EmbeddingGemma 2 per-SoC .litertlm bundles run on the NPU. Read '
    'EmbeddingModel.activeBackend for the backend in use — it is available in '
    'release builds, where this line is not.',
  );
}

/// The legacy web notice: the runtime chooses placement, not this request.
/// New GPU-capable providers report their loaded placement instead.
void noticeWebEmbedderBackendIgnored(PreferredBackend? requested) {
  if (requested == null || _warned) return;
  if (!kDebugMode || edgeAiLogLevel == EdgeAiLogLevel.none) return;
  _warned = true;
  edgeAiLog(
    'ℹ️  preferredBackend ${requested.name} is not applied to embeddings on '
    'web: the runtime picks the accelerator (WebGPU first, WASM as the '
    'fallback; EmbeddingGemma 2 .litertlm runs on WebGPU only). Read '
    'EmbeddingModel.activeBackend: gpu for EmbeddingGemma 2, null when the '
    'runtime does not report one; with LiteRT.js, '
    'window.getLiteRtEmbeddingAccelerator() names it after the first '
    'embedding.',
  );
}

/// An explicit request loaded on a different accelerator. Called once after
/// a new placement-reporting model is adopted, never on reuse. Unlike legacy
/// ignored-request diagnostics, fallback must be visible in release builds.
void noticeEmbedderBackendFallback(
  PreferredBackend? requested,
  PreferredBackend? active,
) {
  if (requested == null || requested == active) return;
  // ignore: avoid_print
  print(
    '[flutter_edge_ai] WARNING: embedding preferredBackend ${requested.name} '
    'fell back to ${active?.name ?? "an unknown accelerator"}. '
    'Read EmbeddingModel.activeBackend for the backend in use.',
  );
}

/// Lets a test assert from a known state. The flag is private and per-isolate
/// otherwise, which is what forces one test to carry every case in order.
@visibleForTesting
void resetEmbedderBackendNotice() => _warned = false;
