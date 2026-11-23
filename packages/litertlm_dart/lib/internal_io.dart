// litertlm_dart's internals that flutter_edge_ai_litertlm builds on and its
// tests drive: the bundle reader and load plan, the NPU stacks and the vendor
// choice, the LLM client and its conversation handles, the EmbeddingGemma 2
// embedder. For this repository's packages only: no compatibility promise,
// changed with any release. Apps use `package:litertlm_dart/litertlm_dart.dart`.
// Native only (dart:ffi, dart:io); the web arm's are internal_web.dart.
library;

export 'internal.dart';

export 'src/bundle/litertlm_bundle_activation.dart'
    show
        BundleActivationRead,
        GpuActivationReason,
        gemma4Fp16MaxContextTokens,
        litertlmDeclaresActivationType,
        tryReadBundleActivationDeclaration;
export 'src/bundle/litertlm_bundle_reader.dart'
    show readBundleInfo, readLiteRtLmHasLinearAttentionState;
export 'src/bundle/litertlm_bundle_sampler.dart'
    show BundleSamplerRead, bundleSamplerFrom, tryReadBundleSampler;
export 'src/bundle/litertlm_flatbuffer.dart'
    show LitertlmFlatBuffer, litertlmHeaderEnd;
export 'src/bundle/litertlm_load_plan.dart'
    show
        LiteRtLmLoadPlan,
        liteRtLmEncoderOnNpu,
        liteRtLmLoadNpuTarget,
        liteRtLmTextCandidates,
        planLiteRtLmLoad,
        textBackendsAllowedForTesting;
export 'src/bundle/litertlm_npu_target.dart' show readLiteRtLmNpuTarget;
export 'src/embedder/embedding_parts.dart'
    show EmbeddingPart, EmbeddingPartKind, embeddingParts;
export 'src/embedder/litert_lm_embedder.dart'
    show
        LiteRtLmEmbedder,
        LiteRtLmEmbeddingConfig,
        LiteRtLmGpuCachePathCheck,
        bindLiteRtLmEmbeddings,
        checkLiteRtLmEmbeddingSymbols,
        liteRtLmCacheDirName,
        liteRtLmCacheDirPrefix,
        liteRtLmCacheFilePathLength,
        liteRtLmEmbeddingSymbols,
        liteRtLmGpuCacheFileNames,
        liteRtLmGpuCachePathCheck,
        liteRtLmGpuCachePathProblem,
        liteRtLmMinWeightCacheBytes,
        liteRtLmNoWeightCacheCauses,
        liteRtLmPathOutsideAscii,
        liteRtLmWrittenGpuCaches,
        liteRtLmWrittenWeightCaches,
        readLiteRtLmMediaTowers,
        requireLiteRtLmAudioEncoder;
export 'src/embedder/litertlm_container_io.dart' show readLitertlmModelTypes;
export 'src/ffi/backend_preference.dart'
    show
        NpuProbes,
        activationDataTypeWireValue,
        encoderBackendWireName,
        ffiBackendFallbackOrder,
        ffiBackendWireName,
        npuNoVendorReason,
        whereNpuRuns;
export 'src/ffi/channel_content_filter.dart' show liteRtLmFiltersChannelContent;
export 'src/ffi/conversation_handles.dart'
    show
        RecoveringConversationHandle,
        ToolCallReader,
        VirtualConversationHandle,
        thoughtChunkPrefix,
        virtualConversationHistoryForTest,
        virtualConversationTokenForTest;

export 'src/ffi/litert_default_scope.dart'
    show openLiteRtLmPreferringDefaultScope, openLiteRtLmRequiringDefaultScope;
export 'src/ffi/litert_lm_client.dart'
    show
        BenchmarkTokens,
        benchmarkInfoOf,
        capturesNativeStderr,
        ConversationHandle,
        EngineCreateRequest,
        EngineCreateResult,
        ExecutorConversation,
        LiteRtLmConversationHandle,
        LiteRtLmFfiClient,
        LiteRtLmLastErrorRead,
        NativeBenchmark,
        NativeBenchmarkTurn,
        NativeLastTurnEnd,
        ScoringStoppedError,
        ScoringStops,
        SendCallGate,
        StoppedTurnRewind,
        StoppedTurnRewindException,
        absResourceExhausted,
        applyThinkingTokenBudget,
        decodeNativeString,
        keepLastSendAfter,
        liteRtLmConstraintFailure,
        npuContextWindowNote,
        sendOffMainIsolate,
        stoppedTurnRewindOutcome,
        streamStartFailureTurnEnd,
        thinkingBudgetChannelWarning;

export 'src/ffi/litert_lm_runtime_check.dart'
    show
        checkLiteRtLmCApiVersion,
        checkLiteRtLmLibrary,
        checkOwnLiteRtLmBuild,
        isUsableLiteRtLmBuild,
        liteRtLmCApiMajor,
        liteRtLmOwnBuildSymbol,
        requireOwnLiteRtLmBuild;
export 'src/ffi/litert_lm_status.dart'
    show LiteRtLmCallException, LiteRtLmLastError;
export 'src/ffi/macos_load_error.dart' show MacOSLoadCause, openMacOSLiteRtLm;
export 'src/ffi/native_turns.dart'
    show
        LiteRtLmTurnCancelledException,
        LiteRtLmTurnClosedException,
        NativeTurn,
        NativeTurnEnd,
        NativeTurnStream,
        NativeTurns;
export 'src/ffi/npu_stack_manifest.dart'
    show
        NativeAssetsManifestReader,
        NpuStackCheck,
        checkNpuStackInManifest,
        qualcommNpuNotEnabledReason;
export 'src/ffi/npu_vendor_host.dart'
    show
        BrokenNpuMaskAux,
        LiteRtLmNpuHost,
        LiteRtLmPlatformNpuHost,
        NpuChoice,
        NpuChosen,
        NpuDispatch,
        NpuPlatform,
        NpuRefused,
        brokenNpuMaskAuxInUse,
        checkIntelNpuStack,
        chooseNpuVendor,
        debugIntelBrokenNpuMaskAux,
        executableDirOf,
        intelBrokenNpuMaskAux,
        npuHwMasking,
        npuStackOf,
        npuStagesWeightBanks,
        prepareAndroidNpuDispatchDir,
        prepareNpuDispatchDir,
        sha256OfFileRange;
export 'src/runtime/constrained_decoding_hosts.dart'
    show
        LiteRtLmConstrainedDecodingRow,
        liteRtLmConstrainedDecodingCandidateRows,
        liteRtLmConstrainedDecodingRefusal,
        liteRtLmConstrainedDecodingRow,
        liteRtLmConstrainedDecodingRows;
export 'src/ffi/open_session_backing.dart'
    show
        AndroidGpuFamily,
        OpenSessionBacking,
        androidGpuFamilyFrom,
        liteRtLmFreshConversationEachTurn,
        liteRtLmFreshConversationNpus,
        liteRtLmOpenSessionBacking;

export 'src/ffi/windows_std_handles.dart'
    show StdHandleCalls, openBundledWindowsLibrary;
export 'src/runtime/build_mode.dart'
    show
        isDebugBuild,
        isFlutterDebugBuild,
        isProductBuild,
        isProfileBuild,
        isReleaseBuild;
export 'src/runtime/native_release.dart' show liteRtLmNativeVersion;
export 'src/runtime/response_text.dart' show extractResponseText;
export 'src/runtime/runtime_log.dart'
    show
        RuntimeLogLevel,
        RuntimeLogSink,
        currentRuntimeLogLevel,
        resetRuntimeLogSink,
        runtimeLog,
        runtimeLogLevel,
        runtimeLogLevelSetByApp,
        runtimeLogLevelSource,
        runtimeLogSink,
        runtimeLogSinkSetByApp;
export 'src/ffi/litert_bindings.dart' show liteRtLmHostLibraryCandidates;
export 'src/api/embedding_engine.dart'
    show checkEmbeddingRequest, createEmbeddingEngineWith, embedderConfigFor;
export 'src/api/backend.dart' show backendKindOf, npuBackendOn, npuPlatformOf;
export 'src/api/conversation.dart'
    show
        conversationForTest,
        conversationHandle,
        conversationTokenCount,
        turnFailureCause;
export 'src/api/benchmark.dart' show llmBenchmarkResultOf;
export 'src/api/conversation.dart' show conversationNativeBenchmark;
export 'src/api/engine.dart'
    show
        minCpuGpuContextTokens,
        EngineHost,
        engineClient,
        engineConversationBacking,
        engineFiltersChannelContent,
        engineForTest,
        engineNoRewindReason,
        contextTokensFor,
        engineContextFor,
        liteRtLmDefaultContextTokens,
        EngineBundle,
        createBenchmarkEngine,
        createEngineWithBundle,
        createConversationWithDefault,
        createOwnConversation,
        engineBundleSampler,
        engineNpuVendor,
        engineRenderUserMessage,
        readEngineBundle,
        debugEngineHost,
        GpuActivationDecision,
        gpuActivationFor,
        resetAndroidGemma4Float16Note,
        liteRtLmNativeLogLevel;
export 'src/api/message.dart'
    show
        messageFromChunk,
        messageFromJson,
        messageJson,
        messageRawJson,
        toolsJson;
export 'src/bundle/litertlm_bundle_sampler.dart'
    show
        LlmModelFamily,
        llmMetadataMaxNumTokens,
        llmModelFamilyFrom,
        readLlmMaxNumTokens,
        readLlmModelFamily;
export 'src/bundle/litertlm_generic_section.dart'
    show genericDataRange, maxGenericDataBytes;
export 'src/ffi/conversation_handles.dart'
    show assistantTurnMessage, concatenatedJsonObjects, nativeToolCalls;
export 'src/ffi/send_options.dart'
    show Constraint, ConversationExtras, SendOptions, sendExtraContext;
export 'src/api/config.dart' show samplerFor;
