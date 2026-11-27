// Refuses a libLiteRtLm this package did not build, or one on another major
// version of the LiteRT-LM C API than the bindings (`checkLiteRtLmCApiVersion`).
//
// Another package can bundle its own LiteRT-LM under the same names: llamadart
// 0.11.1 does by default (LiteRT-LM v0.17.0-8), and llamadart_litert_lm_flutter
// links one through Swift Package Manager. From 0.12.0 llamadart's hook leaves
// its own out when flutter_edge_ai_litertlm is in the app, but an older
// llamadart, or any other package that ships one, still can. On iOS and macOS
// that app still builds: depending on the order of the app's dependencies,
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

import 'package:ffi/ffi.dart';

/// A symbol every libLiteRtLm this package ships exports and upstream
/// LiteRT-LM does not: `patch_c_api.sh` §4c adds it and the Windows `.def`
/// there names it, and the release gate (`check_embedding_exports.py`,
/// `OWN_BUILD_SYMBOLS`) refuses a native archive without it. Not tied to an
/// optional feature (NPU, embeddings): it is an engine setting compiled on
/// every platform.
///
/// Present in native-v0.18.0-g on all seven targets, and absent from
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
    'The LiteRT-LM library at $path is not the one litertlm_dart '
    'ships (it lacks $liteRtLmOwnBuildSymbol). Another package in this app '
    'bundles its own LiteRT-LM under the same name — llamadart before 0.12.0 '
    'does by default. Upgrade llamadart, or set '
    '`hooks: user_defines: llamadart: llamadart_native_runtimes: [llama_cpp]` '
    "in the app's pubspec.yaml and remove llamadart_litert_lm_flutter if it "
    'depends on it; then run `flutter clean` once.',
  );
}

/// The LiteRT-LM C API major version the bindings are generated for
/// (`LITERT_LM_C_API_VERSION_MAJOR` in the vendored `c/engine.h`).
const liteRtLmCApiMajor = 1;

/// The oldest C API minor version of [liteRtLmCApiMajor] this release binds:
/// 1.1 is LiteRT-LM 0.20.0's (native-v0.20.0), which adds the calls a 1.0
/// library (LiteRT-LM 0.19, native-v0.19.x) lacks, such as the tool choice
/// and the LoRA settings.
const liteRtLmCApiMinMinor = 1;

/// Throws [StateError] unless the library opened as [path] reports a C API
/// version [liteRtLmCApiMajor].x, x at least [liteRtLmCApiMinMinor], through
/// `litert_lm_get_api_version` ([readVersion], called only when [provides]
/// has it).
///
/// From 1.0.0 upstream promises semver for the C API, and a library before
/// 1.0.0 does not export the call: its constructors return the object
/// instead of a status, so binding it with these bindings would read a
/// pointer as a status and a status as a pointer. A newer major breaks some
/// call the same way. Nothing here chooses between ABIs at run time; the
/// native bundle this package pins is 1.x.
void checkLiteRtLmCApiVersion(
  bool Function(String symbol) provides,
  ({int code, int major, int minor, int patch}) Function() readVersion, {
  required String path,
}) {
  if (!provides('litert_lm_get_api_version')) {
    throw StateError(
      'The LiteRT-LM library at $path predates its C API 1.0 (it lacks '
      'litert_lm_get_api_version), which this litertlm_dart '
      'release is built against. A stale local prebuilt under '
      'native/litert_lm/prebuilt/ or in the native cache is the usual cause; '
      'run `flutter clean` once.',
    );
  }
  final (:code, :major, :minor, :patch) = readVersion();
  if (code != 0 || major != liteRtLmCApiMajor) {
    throw StateError(
      'The LiteRT-LM library at $path reports C API '
      '${code == 0 ? '$major.$minor.$patch' : 'version unknown (status $code)'}; '
      'this litertlm_dart release is built against '
      '$liteRtLmCApiMajor.x.',
    );
  }
  if (minor < liteRtLmCApiMinMinor) {
    throw StateError(
      'The LiteRT-LM library at $path reports C API $major.$minor.$patch; '
      'this litertlm_dart release is built against '
      '$liteRtLmCApiMajor.$liteRtLmCApiMinMinor or later (LiteRT-LM 0.20.0). '
      'A stale local prebuilt under native/litert_lm/prebuilt/ or in the '
      'native cache is the usual cause; run `flutter clean` once.',
    );
  }
}

/// `litert_lm_get_api_version` on [library].
({int code, int major, int minor, int patch}) _readApiVersion(
  DynamicLibrary library,
) {
  final get = library
      .lookupFunction<
        Int32 Function(Pointer<Int>, Pointer<Int>, Pointer<Int>),
        int Function(Pointer<Int>, Pointer<Int>, Pointer<Int>)
      >('litert_lm_get_api_version');
  final out = calloc<Int>(3);
  try {
    final code = get(out, out + 1, out + 2);
    return (code: code, major: out[0], minor: out[1], patch: out[2]);
  } finally {
    calloc.free(out);
  }
}

/// The C API version [library] reports (`litert_lm_get_api_version`); call
/// only on a library [requireOwnLiteRtLmBuild] passed.
({int code, int major, int minor, int patch}) readLiteRtLmCApiVersion(
  DynamicLibrary library,
) => _readApiVersion(library);

/// Whether a native engine of a library on C API [version] keeps the sampler
/// of its first generation for every later conversation on the CPU and the
/// GPU (google-ai-edge/LiteRT-LM#2080): C API 1.0 (LiteRT-LM 0.19) does, 1.1
/// (LiteRT-LM 0.20.0) builds each conversation's sampler from its own config,
/// measured on macOS arm64 CPU and Metal, Linux x64 CPU and Tesla T4 (Vulkan),
/// Windows x64 CPU and Arc B390 (D3D12), and Android Adreno 830 (Galaxy S25
/// Ultra) and Mali-G715 (Pixel 8a), GPU and CPU. Not measured: iOS (simulator
/// and device Metal), Linux arm64 and Android PowerVR. A version that cannot
/// be read is taken to keep it.
bool liteRtLmSamplerFixedAtFirstGeneration(
  ({int code, int major, int minor, int patch}) version,
) => version.code != 0 || (version.major == 1 && version.minor < 1);

/// Both checks every open of libLiteRtLm makes, in order:
/// [checkOwnLiteRtLmBuild], then [checkLiteRtLmCApiVersion].
void checkLiteRtLmLibrary(
  bool Function(String symbol) provides,
  ({int code, int major, int minor, int patch}) Function() readVersion, {
  required String path,
}) {
  checkOwnLiteRtLmBuild(provides, path: path);
  checkLiteRtLmCApiVersion(provides, readVersion, path: path);
}

/// Returns [library] after [checkLiteRtLmLibrary] on it.
DynamicLibrary requireOwnLiteRtLmBuild(DynamicLibrary library, String path) {
  checkLiteRtLmLibrary(
    library.providesSymbol,
    () => _readApiVersion(library),
    path: path,
  );
  return library;
}

/// Whether [library] passes [requireOwnLiteRtLmBuild]: this package's build,
/// on C API [liteRtLmCApiMajor].x. For choosing among development copies on a
/// host, where a stale one is skipped rather than refused.
bool isUsableLiteRtLmBuild(DynamicLibrary library) {
  try {
    requireOwnLiteRtLmBuild(library, 'a development copy');
    return true;
  } on StateError {
    return false;
  }
}
