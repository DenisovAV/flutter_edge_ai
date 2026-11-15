// LiteRT-LM from Dart: the runtime flutter_edge_ai_litertlm and
// flutter_edge_ai_speech are built on. Native only (dart:ffi); the build hook
// (hook/build.dart) bundles libLiteRtLm and its companions for the target.
//
// What it holds: the bundle reader and load plan, the NPU stacks and the
// vendor choice, the LLM client with its native and virtual sessions (rewind
// of a stopped turn, sampler latch, thinking budget, response constraints),
// the EmbeddingGemma 2 embedder and the option-scoring runtime.
//
// Members named `…ForTest` and those marked `@visibleForTesting` are test
// seams for this repository's packages, outside the compatibility promise.
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
        NpuPlatformBindings,
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
export 'src/ffi/open_session_backing.dart'
    show
        AndroidGpuFamily,
        OpenSessionBacking,
        androidGpuFamilyFrom,
        liteRtLmOpenSessionBacking;

export 'src/ffi/windows_std_handles.dart'
    show StdHandleCalls, openBundledWindowsLibrary;
export 'src/runtime/build_mode.dart'
    show isDebugBuild, isProductBuild, isProfileBuild, isReleaseBuild;
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
        runtimeLogLevelSource,
        runtimeLogSink;
export 'src/ffi/litert_bindings.dart' show liteRtLmHostLibraryCandidates;
