// LiteRtBindings: the LiteRT C API (CompiledModel, tensor buffers,
// accelerators) from the library this package bundles, which
// flutter_edge_ai_speech runs its graphs on. No stability promise beyond the
// C API's own. Native only (dart:ffi); never on the web.
library;

export 'src/ffi/litert_bindings.dart'
    show
        AlignedAlloc,
        LiteRtBindings,
        LiteRtCompiledModel,
        LiteRtEnvironment,
        LiteRtLayoutPosix,
        LiteRtLayoutView,
        LiteRtModel,
        LiteRtOpaqueOptions,
        LiteRtOptions,
        LiteRtRankedTensorTypePosix,
        LiteRtRankedTensorTypeView,
        LiteRtSignature,
        LiteRtStatusX,
        LiteRtTensorBuffer,
        LiteRtTensorBufferRequirements,
        allocAligned,
        kLiteRtElementTypeFloat32,
        kLiteRtElementTypeInt32,
        kLiteRtHostMemoryAlignment,
        kLiteRtHwAcceleratorCpu,
        kLiteRtHwAcceleratorGpu,
        kLiteRtHwAcceleratorNone,
        kLiteRtHwAcceleratorNpu,
        kLiteRtMaxRank,
        kLiteRtStatusOk,
        kLiteRtTensorBufferLockModeRead,
        kLiteRtTensorBufferLockModeReadWrite,
        kLiteRtTensorBufferLockModeWrite;
