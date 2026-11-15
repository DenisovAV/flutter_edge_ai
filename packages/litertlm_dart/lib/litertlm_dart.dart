// LiteRT-LM from Dart: the runtime flutter_edge_ai_litertlm and
// flutter_edge_ai_speech are built on. Native only (dart:ffi); the build hook
// (hook/build.dart) bundles libLiteRtLm and its companions for the target.
//
// What it holds: the bundle reader and load plan, the NPU stacks and the
// vendor choice, the LLM client with its native and virtual sessions (rewind
// of a stopped turn, sampler latch, thinking budget, response constraints),
// the EmbeddingGemma 2 embedder and the option-scoring runtime.
library;

export 'common.dart';

export 'src/bundle/litertlm_bundle_activation.dart'
    show
        BundleActivationRead,
        GpuActivationReason,
        gemma4Fp16MaxContextTokens,
        litertlmDeclaresActivationType,
        tryReadBundleActivationDeclaration;
export 'src/bundle/litertlm_bundle_reader.dart'
    show
        liteRtLmPrefillFits,
        readBundleInfo,
        readLiteRtLmHasLinearAttentionState,
        readLiteRtLmPrefillSignatureLengths;
export 'src/bundle/litertlm_bundle_sampler.dart'
    show
        BundleSamplerRead,
        bundleSamplerFrom,
        executorMetadataHasLinearAttention,
        llmMetadataDeclaresChannel,
        llmMetadataRange,
        readBundleSampler,
        samplerFromLlmMetadata,
        tryReadBundleSampler;
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
export 'src/bundle/litertlm_npu_target.dart'
    show
        liteRtLmLinearAttentionStatePrefixes,
        parseLiteRtStamp,
        readLiteRtLmLinearAttentionState,
        readLiteRtLmNpuTarget,
        readLiteRtLmPrefillLengths;
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
        liteRtLmInputLimit,
        liteRtLmMinWeightCacheBytes,
        liteRtLmNoWeightCacheCauses,
        liteRtLmNpuProbeFailureCauses,
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
        fastRpcProbed,
        ffiBackendFallbackOrder,
        ffiBackendWireName,
        googleTensorDeviceRefusal,
        linuxNpuProbed,
        mediaTekDeviceRefusal,
        npuNoVendorReason,
        npuUnreachable,
        platformNpuProbes,
        whereNpuRuns;
export 'src/ffi/channel_content_filter.dart' show liteRtLmFiltersChannelContent;
export 'src/ffi/conversation_handles.dart'
    show
        RecoveringConversationHandle,
        ToolCallReader,
        VirtualConversationHandle,
        assistantTurnMessage,
        thoughtChunkPrefix,
        virtualConversationHistoryForTest,
        virtualConversationTokenForTest;
export 'src/ffi/engine_create_failure.dart'
    show engineCreateFailureMessage, isGpuArtisanRefusal;
export 'src/ffi/intel_weight_banks.dart'
    show
        IntelWeightBankClaim,
        intelWeightBankDirs,
        intelWeightBankName,
        listIntelWeightBanks,
        sweepStaleIntelWeightBanks,
        windowsBootTime;
export 'src/ffi/litert_default_scope.dart'
    show openLiteRtLmPreferringDefaultScope, openLiteRtLmRequiringDefaultScope;
export 'src/ffi/litert_lm_client.dart'
    show
        ConversationHandle,
        EngineCreateRequest,
        EngineCreateResult,
        ExecutorConversation,
        LiteRtLmConversationHandle,
        LiteRtLmFfiClient,
        LiteRtLmLastErrorRead,
        NativeLastTurnEnd,
        ScoringStoppedError,
        ScoringStops,
        SendCallGate,
        StoppedTurnRewind,
        StoppedTurnRewindException,
        absResourceExhausted,
        applyThinkingTokenBudget,
        createEngineOffMainIsolate,
        createEngineWith,
        decodeNativeString,
        keepLastSendAfter,
        kernelBatchSizeFor,
        liteRtLmConstraintFailure,
        loadWithSystemLoader,
        npuContextWindowNote,
        offMainIsolate,
        preloadNativeLibrary,
        releaseRefusedStreamProxy,
        requireSameLoadedLibrary,
        rewindOffMainIsolate,
        sendOffMainIsolate,
        stoppedTurnRewindOutcome,
        streamProxyV1Entries,
        streamStartFailureTurnEnd,
        thinkingBudgetChannelWarning,
        thinkingExtraContext,
        windowsPreloadLibraries;
export 'src/ffi/litert_lm_library.dart' show openLiteRtLmLibrary;
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
    show
        LiteRtLmCallException,
        LiteRtLmLastError,
        checkLiteRtLmSetter,
        checkLiteRtLmStatus,
        decodeLiteRtLmString,
        lastErrorFrom,
        liteRtLmStatusName,
        liteRtLmStatusOk,
        readLiteRtLmBool,
        readLiteRtLmDouble,
        readLiteRtLmFloat,
        readLiteRtLmInt,
        readLiteRtLmSize;
export 'src/ffi/macos_load_error.dart'
    show
        MacOSLoadCause,
        diagnoseMacOSLoadError,
        dyldErrorText,
        macOSLiteRtLmFramework,
        macOSLoadErrorMessage,
        openMacOSLiteRtLm,
        openMacOSLiteRtLmForTflite;
export 'src/ffi/native_turns.dart'
    show
        LiteRtLmTurnCancelledException,
        LiteRtLmTurnClosedException,
        NativeTurn,
        NativeTurnEnd,
        NativeTurnStream,
        NativeTurns,
        acquireUntilAbort;
export 'src/ffi/npu_stack_manifest.dart'
    show
        NativeAssetsManifestReader,
        NpuStackCheck,
        checkNpuStackInManifest,
        googleTensorNpuNotEnabledReason,
        mediatekNpuNotEnabledReason,
        npuNotBundledReason,
        qualcommNpuNotEnabledReason;
export 'src/ffi/npu_vendor_host.dart'
    show
        BrokenNpuMaskAux,
        LiteRtLmNpuHost,
        LiteRtLmPlatformNpuHost,
        NpuChoice,
        NpuChosen,
        NpuDispatch,
        NpuPlatformBindings,
        NpuRefused,
        brokenNpuMaskAuxInUse,
        checkIntelNpuStack,
        chooseNpuVendor,
        debugIntelBrokenNpuMaskAux,
        executableDirOf,
        intelBrokenNpuMaskAux,
        intelNpuDispatchLib,
        npuHwMasking,
        npuStackOf,
        npuStagesWeightBanks,
        prepareAndroidNpuDispatchDir,
        prepareLinuxNpuDispatchDir,
        prepareNpuDispatchDir,
        sha256OfFileRange,
        windowsNpuDispatchDirOf;
export 'src/ffi/open_session_backing.dart'
    show
        AndroidGpuFamily,
        OpenSessionBacking,
        androidGpuFamilyFrom,
        liteRtLmConversationsAndroidGpus,
        liteRtLmConversationsCpuAbis,
        liteRtLmConversationsGpuAbis,
        liteRtLmConversationsNpus,
        liteRtLmOpenSessionBacking;
export 'src/ffi/option_scoring_ffi.dart'
    show
        nativeText,
        renderUserMessageOffMainIsolate,
        scoreTargetsOffMainIsolate;
export 'src/ffi/stderr_redirect.dart'
    show StderrRedirectResult, redirectStderrKeepingStdout;
export 'src/ffi/stream_start_failure.dart' show streamStartFailureMessage;
export 'src/ffi/windows_std_handles.dart'
    show
        StdHandleCalls,
        alignStdHandles,
        openBundledWindowsLibrary,
        stdErrorHandle,
        stdOutputHandle,
        win32StdHandleCalls;
export 'src/runtime/build_mode.dart'
    show isDebugBuild, isProductBuild, isProfileBuild, isReleaseBuild;
export 'src/runtime/native_release.dart'
    show liteRtLmNativeReleaseTag, liteRtLmNativeVersion;
export 'src/runtime/response_text.dart' show extractResponseText;
export 'src/runtime/runtime_log.dart'
    show
        RuntimeLogLevel,
        RuntimeLogSink,
        currentRuntimeLogLevel,
        resetRuntimeLogSink,
        runtimeLog,
        runtimeLogLevel,
        runtimeLogLevelSource,
        runtimeLogSink,
        sanitizeForLog;
