/// LiteRT-LM (.litertlm) on-device inference engine for flutter_gemma.
///
/// Opt-in. Add to pubspec.yaml and pass an instance to
/// `FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()])`.
///
/// ```dart
/// import 'package:flutter_gemma/flutter_gemma.dart';
/// import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
///
/// await FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()]);
/// ```
library flutter_gemma_litertlm;

export 'src/litert_lm_engine_web.dart'
    if (dart.library.ffi) 'src/litert_lm_engine.dart';

// LiteRt interpreter FFI (arbitrary `.tflite` models) — used by
// flutter_gemma_speech. `dart.library.ffi`-only;
// the web stub exports no symbols (web leaves use their own JS arm).
export 'src/ffi/litert_bindings_stub.dart'
    if (dart.library.ffi) 'src/ffi/litert_bindings.dart';

// LiteRT embedding backend (`LiteRtEmbeddingBackend`) — moved from
// flutter_gemma_embeddings (embedder decoupling, 1.5.0). Native arm builds a
// `ForwardPassDescriptor` over the LiteRT C API forward pass; web arm builds
// the LiteRT.js-backed `WebEmbeddingModel` directly.
// Where the LiteRT.js WASM runtime is fetched from on web. Plain Dart with no
// imports at all, so it is exported unconditionally: an app sets it once at
// startup, and on native it is simply inert. The web MODEL beside it is not
// exported here — it pulls dart:js_interop, which must not reach a native build.
export 'src/embedding/web/web_runtime.dart';

export 'src/embedding/litert_embedding_backend_web.dart'
    if (dart.library.ffi) 'src/embedding/litert_embedding_backend.dart';

// Hugging Face resolver for repos that ship a `litertlm_manifest.json`
// deployment manifest. `LiteRtLmEngine` carries it (it implements
// `HuggingFaceResolverSource`), so registering the engine registers this too;
// pass `huggingFaceResolvers:` only to OVERRIDE, e.g. a pinned
// `LitertlmManifestResolver(revision: 'abc123')`. Drive it via
// `FlutterGemma.resolveHuggingFace(repo, fileType: ModelFileType.litertlm)`,
// or resolve and install in one call with
// `installModel(...).fromHuggingFace(repo)`. All six platforms (its IO arm
// picks dart:io or browser fetch internally).
export 'src/manifest/litertlm_manifest_resolver.dart'
    show LitertlmManifestResolver, ManifestFetch, ManifestFetchException;
