// Refuses a libLiteRtLm this package did not build.
//
// Another package can bundle its own LiteRT-LM under the same names: llamadart
// 0.11.1 does by default (LiteRT-LM v0.17.0-8). From 0.12.0 llamadart's hook
// leaves it out when flutter_edge_ai_litertlm is in the app, but an older
// llamadart, or any other package that ships one, still can. On iOS that app
// still builds —
// Flutter renames our framework to `LiteRtLm1.framework`, and
// `LiteRtLm.framework`, the path every loader here opens, is the other
// package's build. Without this check the engine binds it and fails later, in
// a way that names neither cause. Android, Linux and Windows fail that build
// loudly, but a hand-assembled bundle can still hand us a foreign library.
//
// Every place this package opens libLiteRtLm checks the handle right after the
// open, before anything binds it: `openLiteRtLmLibrary` (the LLM isolate
// helpers and the EmbeddingGemma 2 pass), `LiteRtLmFfiClient._ensureBindings`
// (the LLM engine) and `_openLiteRt` in litert_bindings.dart where it opens
// libLiteRtLm — Apple and Android, where the LiteRT C API lives inside it (the
// `.tflite` embedding pass and flutter_edge_ai_speech).

import 'dart:ffi';

/// A symbol every libLiteRtLm this package ships exports and upstream
/// LiteRT-LM does not: `patch_c_api.sh` §4c adds it, the Windows `.def` there
/// names it, and the LLM client calls it (Android GPU, #364), so it cannot
/// leave the patch without breaking our own code. Not tied to an optional
/// feature (NPU, embeddings): it is an engine setting compiled on every
/// platform.
///
/// Checked in native-v0.18.0-e on all seven targets, and absent from
/// llamadart's LiteRT-LM v0.17.0-8. At a pin bump, confirm that upstream has
/// not added it.
const liteRtLmOwnBuildSymbol =
    'litert_lm_engine_settings_set_kernel_batch_size';

/// Throws [StateError] when [provides] reports [liteRtLmOwnBuildSymbol]
/// missing from the library opened as [path].
///
/// A [StateError], not an [Exception]: `initializeFfiRuntime`'s backend
/// fallback loop catches `on Exception`, and would retry the same foreign
/// library once per backend and report the last attempt instead of this.
void checkOwnLiteRtLmBuild(
  bool Function(String symbol) provides, {
  required String path,
}) {
  if (provides(liteRtLmOwnBuildSymbol)) return;
  throw StateError(
    'The LiteRT-LM library at $path is not the one flutter_edge_ai_litertlm '
    'ships (it lacks $liteRtLmOwnBuildSymbol). Another package in this app '
    'bundles its own LiteRT-LM under the same name — llamadart before 0.12.0 '
    'does by default. Upgrade llamadart, or set '
    '`hooks: user_defines: llamadart: llamadart_native_runtimes: [llama_cpp]` '
    "in the app's pubspec.yaml; then run `flutter clean` once.",
  );
}

/// Returns [library] after [checkOwnLiteRtLmBuild] on it.
DynamicLibrary requireOwnLiteRtLmBuild(DynamicLibrary library, String path) {
  checkOwnLiteRtLmBuild(library.providesSymbol, path: path);
  return library;
}
