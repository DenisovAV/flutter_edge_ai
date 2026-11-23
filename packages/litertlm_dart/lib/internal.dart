// The web-safe internals of litertlm_dart that flutter_edge_ai_litertlm's web
// arm and catalog share with the runtime: its vocabulary, bundle-info types,
// NPU stacks, embedder types and limits, load errors, the conversation handle
// and the web runtime's pure-Dart half (the page lock, the session config,
// the EmbeddingGemma 2 web embedder over an injected runtime). No dart:io, no
// dart:ffi, no dart:js_interop: VM tests import it. For this repository's
// packages only: no compatibility promise.
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
    show
        LibraryLoadArgumentError,
        LibraryLoadFailedException,
        LibraryLoadFailure,
        LibraryLoadStateError,
        LibraryLoadUnsupportedError,
        markLibraryLoadFailure,
        LiteRtLmEngineCreateException,
        NpuDispatchUnavailableException;
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
export 'src/api/conversation.dart'
    show conversationForTest, conversationHandle, turnFailureCause;
export 'src/api/embedding_engine_config.dart'
    show checkEmbeddingRequest, embedderInputOfContents;
export 'src/api/message.dart' show messageJson, messageRawJson, toolsJson;
export 'src/api/config.dart' show samplerFor;
export 'src/ffi/native_turns.dart'
    show LiteRtLmTurnCancelledException, LiteRtLmTurnClosedException;
export 'src/runtime/conversation_handle.dart'
    show
        ConversationHandle,
        NativeBenchmark,
        NativeBenchmarkTurn,
        NativeLastTurnEnd,
        StoppedTurnRewind,
        StoppedTurnRewindException;
export 'src/runtime/runtime_log.dart'
    show
        RuntimeLogLevel,
        RuntimeLogSink,
        runtimeLog,
        runtimeLogLevelSetByApp,
        runtimeLogLevelSource,
        runtimeLogSink,
        runtimeLogSinkSetByApp;
export 'src/runtime/send_options.dart' show SendOptions;
export 'src/web/page_lock.dart'
    show
        LiteRtLmPageLease,
        LiteRtLmPageLock,
        LiteRtLmPagePoisonedError,
        liteRtLmPageLock;
export 'src/web/web_embedder.dart'
    show
        LiteRtLmWebAudio,
        LiteRtLmWebBackend,
        LiteRtLmWebEmbedder,
        LiteRtLmWebEmbedderConfig,
        LiteRtLmWebEmbedderInfo,
        LiteRtLmWebEmbedding,
        LiteRtLmWebEmbeddingOptions,
        LiteRtLmWebEngine,
        LiteRtLmWebEngineSettings,
        LiteRtLmWebGpuSupport,
        LiteRtLmWebImage,
        LiteRtLmWebInput,
        LiteRtLmWebOverflowStrategy,
        LiteRtLmWebParts,
        LiteRtLmWebRuntime,
        LiteRtLmWebRuntimeState,
        LiteRtLmWebText,
        liteRtLmWebAudioBackend,
        liteRtLmWebShimLine,
        requireLiteRtLmWebAudioEncoder,
        requireLiteRtLmWebAudioEncoderFor;
export 'src/web/web_runtime_version.dart'
    show
        liteRtLmWebModuleUrl,
        liteRtLmWebRuntime,
        liteRtLmWebRuntimeVersion,
        webMediaPathMessage;
export 'src/web/web_session_config.dart' show samplerTypeTopP, webSessionConfig;
