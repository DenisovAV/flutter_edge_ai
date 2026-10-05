// Resolves the active web inference model into the Transformers.js
// (`@huggingface/transformers`) repo id it should load. Pure Dart — no
// `dart:js_interop` — but see this file's class doc for why it is still
// NOT VM-testable in isolation (transitively depends on `WebModelManager`,
// which is web-only).
import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/model_management/managers/web_model_manager.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;

import 'transformers_repo_id.dart';

/// Derives a Transformers.js repo id (`<owner>/<name>`) from the active
/// inference model's [ModelSource].
///
/// Mirrors `WebModelSourceResolver`'s shape (a `forActiveModel()` factory
/// over a fresh [WebModelManager]) but resolves an identity STRING instead
/// of a downloadable model source — Transformers.js resolves + caches the
/// repo itself (browser Cache Storage / IndexedDB) from the id alone, so
/// core's `ModelFileType.onnx` web install is fileless (see
/// `WebModelManager`'s `downloadModelWithProgress`/restore branches) and
/// there is never an on-disk/blob path to hand back here.
///
/// NOTE: importing `WebModelManager` pulls in `WebDownloadService`, which
/// itself imports `dart:js_interop` — so despite having zero direct
/// `dart:js_interop` imports, this file is STILL not importable from a VM
/// (`flutter test`) run. It is compile-checked by `flutter build web` only,
/// same as every other file under `lib/src/web/`.
class TransformersWebResolver {
  TransformersWebResolver(this._modelManager);

  /// Builds a resolver backed by a fresh [WebModelManager], which rehydrates
  /// the active model from persisted prefs. Lets [OnnxEngine] (web) construct
  /// the resolver without a `FlutterGemmaWeb` instance — same pattern as
  /// `WebModelSourceResolver.forActiveModel()`.
  factory TransformersWebResolver.forActiveModel() =>
      TransformersWebResolver(WebModelManager());

  final WebModelManager _modelManager;

  /// Resolves the active inference model's Transformers.js repo id. See
  /// [transformersRepoIdFromSource] for the [ModelSource] → repo id mapping.
  Future<String> resolveActiveRepoId() async {
    // A resolver built via `forActiveModel()` holds a FRESH WebModelManager
    // whose active identity is rehydrated from prefs asynchronously — await
    // the restore before reading `activeInferenceModel`, same reasoning as
    // `WebModelSourceResolver.resolveActiveInferenceModel`.
    await _modelManager.ensureInitialized();
    final active = _modelManager.activeInferenceModel;
    if (active == null) {
      throw StateError(
        'No active inference model set. Use FlutterGemma.installModel() first.',
      );
    }
    if (active is! InferenceModelSpec) {
      throw StateError(
        'Active model is not an inference model spec (${active.runtimeType}).',
      );
    }
    return transformersRepoIdFromSource(active.modelSource);
  }
}
