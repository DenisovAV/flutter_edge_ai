// The web-safe internals of litertlm_dart that flutter_edge_ai_litertlm's web
// arm and catalog share with the runtime: its vocabulary, bundle-info types,
// NPU stacks, embedder types and limits, load errors. No dart:io, no dart:ffi.
// For this repository's packages only: no compatibility promise.
library;

export 'src/runtime/types.dart'
    show
        ActivationDataType,
        BackendKind,
        BundleSampler,
        CancelSignal,
        MediaOrder,
        MediaSide,
        Sampler,
        ScoringRun,
        BenchmarkInfo;
export 'src/runtime/errors.dart'
    show ConstraintUnsupportedException, ScoringCancelledException;
export 'src/runtime/load_errors.dart'
    show LiteRtLmEngineCreateException, NpuDispatchUnavailableException;
export 'src/runtime/litert_lm_log_level.dart' show LiteRtLmLogLevel;
export 'src/runtime/npu_stacks.dart'
    show
        NpuStack,
        androidLibFileName,
        googleTensorNpuLibs,
        nativeAssetId,
        npuSentenceList,
        npuStackLibs;
export 'src/bundle/litertlm_bundle_info.dart'
    show
        BundleInfo,
        BundleSection,
        LiteRtLmBundleException,
        LiteRtLmBundleProblem,
        NpuStamp,
        npuVendorOf;
export 'src/embedder/embedder_types.dart'
    show
        EmbedderEngineException,
        EmbedderInfo,
        EmbedderInput,
        EmbedderInputTooLongException,
        EmbedderLoadException,
        EmbedderModality;
export 'src/embedder/embedder_constants.dart'
    show
        liteRtLmAudioBundle,
        liteRtLmDefaultVisionTokensPerImage,
        liteRtLmMaxInputLength,
        liteRtLmNoAudioEncoderMessage,
        liteRtLmUnreadableContainerMessage,
        liteRtLmVisionTokenBudgets;
export 'src/embedder/litertlm_container.dart'
    show
        litertlmHasAudioEncoder,
        litertlmHasAudioTower,
        litertlmHasVisionTower,
        readLitertlmModelTypesFrom;
export 'src/ffi/engine_sampler_latch.dart' show EngineSamplerLatch;
export 'src/ffi/thinking_context.dart' show thinkingContext;
export 'src/runtime/native_hosts.dart'
    show
        LiteRtLmEg2Bundle,
        liteRtLmEmbeddingGpuAbis,
        liteRtLmEmbeddingGpuMeasured,
        liteRtLmEmbeddingGpuRefusedAbis,
        liteRtLmNativeAbis;
