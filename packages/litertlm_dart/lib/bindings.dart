// The raw dart:ffi bindings to LiteRT-LM's C API (inference and the
// EmbeddingEngine), ffigen output at the native pin. No stability promise
// beyond the C API's own. Native only (dart:ffi); never on the web.
library;

export 'src/ffi/litert_lm_bindings.dart';
export 'src/ffi/litert_lm_embedding_bindings.dart'
    hide
        LiteRtLmActivationDataType,
        LiteRtLmInputData,
        LiteRtLmInputDataType,
        LiteRtLmSamplerType,
        LiteRtLmStatusCode;
