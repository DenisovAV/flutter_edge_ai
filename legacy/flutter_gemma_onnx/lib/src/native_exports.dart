// Native-only advanced/test surface for `flutter_gemma_onnx` (ONNX web PR,
// `feat/onnx-web`, barrel-split Task 1). Reached only via the top-level
// barrel's conditional export:
//
//   export 'src/native_exports_stub.dart'
//       if (dart.library.ffi) 'src/native_exports.dart';
//
// This is the `dart:ffi`-only half of what the barrel used to export
// unconditionally — direct construction of [GenAiClient]/[GenAiFfiClient]
// (advanced FFI client access) and the plain-ORT embedding forward-pass
// pieces ([OnnxEmbeddingForwardPass],
// [OrtClient]) used by tests/advanced callers that build a custom client.
// Mirrors `flutter_gemma_litertlm`'s `litert_bindings_stub.dart` pattern: the
// web arm (`native_exports_stub.dart`) exports NO symbols at all — web
// engine packages build their own JS-interop-backed equivalents instead (see
// `src/web/`).
library;

export 'ffi/gen_ai_client.dart'
    show GenAiClient, GenAiFfiClient, GenAiTurn, GenAiGenerationStats;
export 'onnx_inference_model.dart';
export 'onnx_session.dart';
export 'embedding/onnx_embedding_forward_pass.dart';
export 'embedding/ort_client.dart';
