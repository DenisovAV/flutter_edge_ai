// Resolves the active web inference model into the Transformers.js
// (`@huggingface/transformers`) repo id it should load. No direct
// `dart:js_interop` import, but it is still NOT VM-testable in isolation: core's
// `WebModelSourceResolver` (engine_web.dart) is web-only.
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';

import 'transformers_repo_id.dart';

/// Derives a Transformers.js repo id (`<owner>/<name>`) from the active
/// inference model's [ModelSource].
///
/// Built over core's [WebModelSourceResolver], but resolves an identity
/// STRING instead of a downloadable model source — Transformers.js resolves +
/// caches the repo itself (browser Cache Storage / IndexedDB) from the id
/// alone, so core's `ModelFileType.onnx` web install is fileless and there is
/// never an on-disk/blob path to hand back here.
///
/// NOTE: `WebModelSourceResolver` lives in core's web-only library, so this
/// file is not importable from a VM (`flutter test`) run. It is compile-checked
/// by `flutter build web` only, same as every other file under `lib/src/web/`.
class TransformersWebResolver {
  TransformersWebResolver._(this._sourceResolver);

  /// Builds a resolver over core's [WebModelSourceResolver.forActiveModel],
  /// which rehydrates the active model from persisted prefs. Lets
  /// [OnnxEngine] (web) construct the resolver without a `FlutterEdgeAiWeb`
  /// instance.
  factory TransformersWebResolver.forActiveModel() =>
      TransformersWebResolver._(WebModelSourceResolver.forActiveModel());

  final WebModelSourceResolver _sourceResolver;

  /// Resolves the active inference model's Transformers.js repo id. See
  /// [transformersRepoIdFromSource] for the [ModelSource] → repo id mapping.
  ///
  /// Throws [StateError] when no inference model is active (core awaits the
  /// persisted-identity restore first; see
  /// [WebModelSourceResolver.activeInferenceSpec]).
  Future<String> resolveActiveRepoId() async {
    final active = await _sourceResolver.activeInferenceSpec();
    return transformersRepoIdFromSource(active.modelSource);
  }
}
