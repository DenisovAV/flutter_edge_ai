// The EmbeddingGemma 2 vision budget (R5 D25): how many vision tokens the
// `.litertlm` pass gives one image. Shared by both arms of
// `LiteRtEmbeddingBackend`, so a budget is refused the same way everywhere.
// Web-safe: imports only core's engine library.
//
// Measured on the 440m bundle (eg2_design_backup/measurements, X2): 140 is the
// closest to the reference model's own 280 (min cos 0.985 over 10 images) and
// is what the bundle uses when nothing is set; 70 is about twice as fast (0.25
// vs 0.55 s per image on an M4 Pro) at min cos 0.970. Natively, 200 and 280
// fail with code 3, while 1, 35, 100 and 141 are accepted SILENTLY and change
// the vectors — so anything but those two is refused in Dart, before any
// engine exists.

import 'package:flutter_edge_ai/engine.dart';

/// The default vision budget: 140 tokens per image (profile ids `-vis140`).
const liteRtLmDefaultVisionTokensPerImage = 140;

/// Every vision budget `LiteRtEmbeddingBackend` accepts.
const liteRtLmVisionTokenBudgets = [140, 70];

/// Throws [EmbeddingLoadException] (as [engine]) unless [visionTokensPerImage]
/// is one of [liteRtLmVisionTokenBudgets].
void checkVisionTokensPerImage(
  int visionTokensPerImage, {
  required String engine,
}) {
  if (liteRtLmVisionTokenBudgets.contains(visionTokensPerImage)) return;
  throw EmbeddingLoadException(
    'LiteRtEmbeddingBackend(visionTokensPerImage: $visionTokensPerImage) is '
    'not supported: use 140 (the default) or 70. EmbeddingGemma 2 has vision '
    'signatures for those two budgets only; a larger value fails to load and '
    'any other value silently changes the image vectors.',
    engine: engine,
  );
}
