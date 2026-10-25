// The one-time notice that `LiteRtEmbeddingBackend(requireWeightCache: true)`
// does not apply to a load. Web-safe: both arms call it from describe(), on
// the caller's isolate.

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

/// Said once per isolate: the flag is set at registration, so every load
/// would repeat the same line. Per-isolate, as a top-level mutable is.
bool _noticed = false;

/// Says, once per isolate and in debug builds only (`edgeAiLog`), that
/// `LiteRtEmbeddingBackend(requireWeightCache: true)` does not apply to the
/// load being described, and [why]: a `.tflite` embedder, an NPU load
/// without declared audio, or the web. The backend accepts the flag on every
/// path so that one registration compiles everywhere; accepting it in silence
/// is what core's `noticeEmbedderBackendIgnored` exists to avoid. Nothing
/// here changes what runs.
void noticeRequireWeightCacheNotApplied(String why) {
  if (_noticed) return;
  // Spend the one shot only on a line that can appear, as core's notices do:
  // an app that starts silent and raises the level later still gets it.
  if (!kDebugMode || edgeAiLogLevel == EdgeAiLogLevel.none) return;
  _noticed = true;
  edgeAiLog(
    'ℹ️  LiteRtEmbeddingBackend(requireWeightCache: true) does not apply to '
    'this load: $why. It applies to EmbeddingGemma 2 .litertlm bundles on '
    'CPU, and on the NPU to the audio tower of a load with declared audio.',
  );
}

/// Lets a test start from a known state.
@visibleForTesting
void resetRequireWeightCacheNotice() => _noticed = false;
