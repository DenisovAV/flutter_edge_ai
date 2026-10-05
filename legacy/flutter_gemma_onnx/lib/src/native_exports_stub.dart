// Web arm of the `native_exports.dart` conditional export (ONNX web PR,
// `feat/onnx-web`, barrel-split Task 1). Exports NOTHING — the `dart:ffi`
// advanced/test surface ([GenAiClient]/[GenAiFfiClient],
// [OnnxEmbeddingForwardPass]/[OrtClient],
// [OnnxInferenceModel]/[OnnxSession]) has no meaning on web; the web arm's
// equivalents live under `src/web/` and are reached through the top-level
// barrel's OTHER conditional exports (`OnnxEngine`, `OnnxEmbeddingBackend`),
// never through this one. Mirrors `flutter_gemma_litertlm`'s
// `litert_bindings_stub.dart`.
library;
