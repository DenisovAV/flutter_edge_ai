/// ONNX Runtime on-device engines for flutter_gemma: text generation
/// (`OnnxEngine`, native macOS/Linux/Windows/Android/iOS arm via ORT-GenAI
/// PLUS a web arm via Transformers.js, see below) and embeddings
/// (`OnnxEmbeddingBackend`, productionized on native + web).
///
/// Opt-in. Add to pubspec.yaml and pass instances to
/// `FlutterGemma.initialize(...)`.
///
/// **Inference (`OnnxEngine`)** — see [OnnxEngine]'s doc comment.
/// - **Native** (macOS/Linux/Windows/Android/iOS): text-only, greedy
///   decoding, one session at a time, over ORT-GenAI via `dart:ffi`
///   (`GenAiFfiClient`, a long-lived worker isolate — no FFI handle ever
///   crosses an isolate boundary).
/// - **Web**: text generation via Transformers.js v4
///   (`@huggingface/transformers`) — a different model-provisioning +
///   execution story than the native arm: the model is identified by its
///   Hugging Face repo id (not an ORT-GenAI directory), Transformers.js
///   resolves + caches the repo itself, and the pipeline is stateless per
///   call (the session resends the whole chat history every turn). See
///   `OnnxWebInferenceModel`'s module doc (`lib/src/web/`) for the details.
///
/// **Embeddings (`OnnxEmbeddingBackend`)** — a plain ONNX Runtime forward
/// pass (no ORT GenAI) over an `.onnx`/`.ort` embedding model directory.
/// Native: `dart:ffi`, both MiniLM-family (WordPiece) and
/// EmbeddingGemma-300M-ONNX (SentencePiece) route through one factory, see
/// `OnnxEmbeddingBackend`'s doc comment. **Web**: `onnxruntime-web`
/// (WebGPU/WASM), WordPiece (MiniLM-family) only in this release —
/// SentencePiece needs a pure-Dart parser that doesn't exist yet (native's
/// `dart_sentencepiece_tokenizer` is `dart:io`/`dart:isolate`-only).
///
/// ```dart
/// import 'package:flutter_gemma/flutter_gemma.dart';
/// import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';
/// import 'package:flutter_gemma_onnx/flutter_gemma_onnx.dart';
///
/// await FlutterGemma.initialize(
///   inferenceEngines: [OnnxEngine()],
///   embeddingBackends: [OnnxEmbeddingBackend()],
///   embeddingTokenizers: [GemmaEmbeddingTokenizers()],
/// );
///
/// await FlutterGemma.installEmbedder()
///     .modelFromAsset('assets/models/all-MiniLM-L6-v2.onnx')
///     .tokenizerFromAsset('assets/models/tokenizer.json')
///     .install();
/// ```
library;

// `OnnxEngine`/`OnnxEmbeddingBackend` are conditionally exported so the SAME
// public API compiles on both native (dart:ffi) and web — mirrors
// `flutter_gemma_litertlm`'s barrel exactly. See `src/web/` for the web
// arms and each web file's module doc for what differs from native.
export 'src/web/onnx_engine_web.dart'
    if (dart.library.ffi) 'src/onnx_engine.dart';
export 'src/web/onnx_embedding_backend_web.dart'
    if (dart.library.ffi) 'src/embedding/onnx_embedding_backend.dart';

// Native-only advanced/test surface — direct construction of the ORT-GenAI
// FFI client, the plain-ORT embedding forward pass, or a custom `OrtClient`
// (fakes for unit tests). Exports NO symbols on web — see
// `src/native_exports_stub.dart`'s doc for why (mirrors
// `flutter_gemma_litertlm`'s `litert_bindings_stub.dart`).
export 'src/native_exports_stub.dart'
    if (dart.library.ffi) 'src/native_exports.dart';

// The Hugging Face resolver (pure Dart, web-safe) — owns the
// `ModelFileType.onnx` slot so `fromHuggingFace(repo)` installs an ORT-GenAI
// directory (native) or a fileless repo-id model (web). `HfFetch` /
// `HfFetchException` are its injectable HTTP seam (test/app fakes), mirroring
// litertlm's exported `ManifestFetch` / `ManifestFetchException`.
export 'src/onnx_hugging_face_resolver.dart' show OnnxHuggingFaceResolver;
export 'src/hf/hf_fetch_types.dart' show HfFetch, HfFetchException;
