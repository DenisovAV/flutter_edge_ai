// The web-safe part of litertlm_dart: the runtime's vocabulary (backends,
// samplers, NPU stacks, bundle-info types, embedder types and limits, load
// errors), with no dart:io and no dart:ffi, so code that names them compiles
// for the web. `litertlm_dart.dart` exports all of it too.
library;

export 'src/runtime/types.dart'
    show
        ActivationType,
        Backend,
        BundleSampler,
        CancelSignal,
        MediaOrder,
        MediaSide,
        Sampler,
        ScoringRun,
        TurnMetrics;
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
        mediatekNpuRefused,
        mediatekNpuRefusedReason,
        nativeAssetId,
        npuSentenceList,
        npuStackLibs,
        offeredNpuStacks;
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
