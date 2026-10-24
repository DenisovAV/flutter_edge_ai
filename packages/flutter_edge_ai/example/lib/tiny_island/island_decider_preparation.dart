// The Decider API is @experimental; Tiny Island is its demo.
// ignore_for_file: experimental_member_use

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'island_decider_recipe.dart';
import 'island_decider_store.dart';

/// A Tiny Island decider ready to choose, and how it came to be — every
/// part of that is shown on the status line, so no path is silent.
final class PreparedIslandDecider {
  const PreparedIslandDecider({
    required this.decider,
    required this.loaded,
    this.stored = false,
    this.refitReason,
    this.storeProblem,
  });

  final Decider decider;

  /// True when it was loaded from the store; false when it was fitted.
  final bool loaded;

  /// True when a fitted decider was written to the store (a later
  /// [storeProblem] is then about cleaning up older ones).
  final bool stored;

  /// Why a stored decider was not used and the decider was fitted again;
  /// null when there was none to use.
  final String? refitReason;

  /// What went wrong storing the fitted decider (or, when [stored], removing
  /// an older one); null when nothing did.
  final String? storeProblem;
}

/// The decider for [recipe] on [embedder]: the one [store] holds for [model]
/// when it loads into this embedder's space and has these options, else a
/// fresh fit — stored for the next visit.
///
/// A stored decider that cannot be read, was fitted in another embedding
/// space (`DeciderSpaceMismatchException`: another file, backend or
/// dimension) or for other actions is replaced, and [PreparedIslandDecider.
/// refitReason] says which. Fitting is the decider's own calibration in
/// THIS space, so the CPU bundle, an NPU bundle and the web each get a
/// threshold measured on their own vectors.
///
/// [onProgress] and [cancelToken] go to `createDecider`. Failures of the
/// fit (and of the embedder) are thrown; failures of the store are not —
/// they are reported in the result.
Future<PreparedIslandDecider> prepareIslandDecider({
  required EmbeddingModel embedder,
  required String model,
  required IslandDeciderRecipe recipe,
  required IslandDeciderStore store,
  required CancelToken cancelToken,
  required void Function(int done, int total) onProgress,
  String? embedderId,
}) async {
  final fingerprint = recipe.fingerprint;
  String? refitReason;
  Map<String, Object?>? artifact;
  try {
    artifact = await store.read(model: model, fingerprint: fingerprint);
  } catch (e) {
    refitReason = 'the stored decider could not be read ($e)';
  }
  if (artifact != null) {
    try {
      final decider = await embedder.loadDecider(
        artifact,
        embedderId: embedderId,
      );
      if (recipe.matches(decider)) {
        return PreparedIslandDecider(decider: decider, loaded: true);
      }
      await decider.close();
      refitReason = 'the stored decider was fitted for other actions';
    } on DeciderSpaceMismatchException catch (e) {
      refitReason =
          'the stored decider was fitted in another embedding space '
          '(${e.expected}; this embedder is ${e.actual})';
    } on FormatException catch (e) {
      refitReason = 'the stored decider is not readable (${e.message})';
    }
  }
  if (refitReason != null) {
    debugPrint('[TinyIsland] fitting again: $refitReason');
  }

  final decider = await embedder.createDecider(
    options: recipe.options,
    method: recipe.method,
    calibration: recipe.calibration,
    embedderId: embedderId,
    cancelToken: cancelToken,
    onProgress: onProgress,
  );
  String? storeProblem;
  var stored = false;
  try {
    storeProblem = await store.write(
      model: model,
      fingerprint: fingerprint,
      artifact: decider.toArtifact(),
    );
    stored = true;
  } catch (e, st) {
    storeProblem = 'it could not be stored ($e)';
    debugPrint('[TinyIsland] storing the decider failed: $e\n$st');
  }
  return PreparedIslandDecider(
    decider: decider,
    loaded: false,
    stored: stored,
    refitReason: refitReason,
    storeProblem: storeProblem,
  );
}
