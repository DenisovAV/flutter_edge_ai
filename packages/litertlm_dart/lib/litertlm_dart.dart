// LiteRT-LM from Dart, shaped like its Kotlin and Swift APIs: an [Engine]
// loads a `.litertlm` model on a [Backend], a [Conversation] streams replies
// to [Message]s, an [EmbeddingEngine] embeds with EmbeddingGemma 2. Natively
// over dart:ffi (the build hook bundles libLiteRtLm for the target); on the
// web over the page's `@litert-lm/core` (dart:js_interop), with the same
// types. What the web runtime does not have (reading a file by path, the NPU,
// the tokenizer, option scoring, the benchmark mode) is an UnsupportedError
// there.
//
// What it adds to the official APIs: several conversations per engine with
// a stopped turn recovered, the NPU vendor
// chosen from the bundle, the bundle read without loading it ([BundleInfo]),
// tokenize and option scoring, and EmbeddingGemma 2's images and audio.
library;

export 'src/api/backend.dart'
    show
        Backend,
        CpuBackend,
        GpuBackend,
        NpuBackend,
        SpeculativeDecodingConfig,
        SpeculativeDecodingMode;
export 'src/api/benchmark.dart'
    if (dart.library.js_interop) 'src/web/native_only_web.dart'
    show benchmark;
export 'src/api/benchmark_result.dart' show LlmBenchmarkResult;
export 'src/api/bundle.dart' show BundleInfoBackends;
export 'src/api/config.dart'
    show
        ConversationConfig,
        EngineConfig,
        JsonResponseFormat,
        LoraConfig,
        NoRepeatNgramConfig,
        RegexResponseFormat,
        RepetitionPenaltyConfig,
        ResponseFormat,
        SamplerConfig,
        ThinkingConfig,
        ToolChoice,
        ToolChoiceAllowedTools,
        ToolChoiceAuto,
        ToolChoiceForcedFunction,
        ToolChoiceNone,
        ToolChoiceRequired,
        maxThinkingTokenBudget;
export 'src/api/conversation.dart'
    show
        ContextFullException,
        Conversation,
        ConversationClosedException,
        TurnFailedException;
export 'src/api/embedding_engine.dart'
    if (dart.library.js_interop) 'src/web/embedding_engine_web.dart'
    show EmbeddingEngine;
export 'src/api/embedding_engine_config.dart' show EmbeddingEngineConfig;
export 'src/api/engine.dart'
    if (dart.library.js_interop) 'src/web/engine_web.dart'
    show Engine;
export 'src/api/log.dart' show LiteRtLmLog;
export 'src/api/session.dart'
    show
        AudioInputData,
        ImageInputData,
        InputData,
        Session,
        SessionConfig,
        TextInputData;
export 'src/api/message.dart'
    show
        AudioBytesContent,
        AudioFileContent,
        Content,
        ImageBytesContent,
        ImageFileContent,
        Message,
        Role,
        TextContent,
        Tool,
        ToolCall,
        ToolResponseContent;
export 'src/bundle/litertlm_bundle_info.dart'
    show
        BundleInfo,
        BundleSection,
        LiteRtLmBundleException,
        LiteRtLmBundleProblem,
        NpuStamp;
export 'src/bundle/litertlm_bundle_reader.dart'
    if (dart.library.js_interop) 'src/web/native_only_web.dart'
    show readBundleInfo;
export 'src/bundle/litertlm_generic_section.dart'
    if (dart.library.js_interop) 'src/web/native_only_web.dart'
    show readBundleGenericData;
export 'src/embedder/embedder_types.dart'
    show
        EmbedderEngineException,
        EmbedderInfo,
        EmbedderInputTooLongException,
        EmbedderLoadException,
        EmbedderModality;
export 'src/runtime/errors.dart'
    show
        ConstraintUnsupportedException,
        LiteRtLmException,
        LiteRtLmNativeException,
        ScoringCancelledException;
export 'src/runtime/litert_lm_log_level.dart' show LiteRtLmLogLevel;
export 'src/runtime/load_errors.dart'
    show
        LiteRtLmEngineCreateException,
        LiteRtLmLibraryException,
        NpuDispatchUnavailableException;
export 'src/runtime/runtime_log.dart' show RuntimeLogSink;
export 'src/runtime/types.dart'
    show
        ActivationDataType,
        BackendKind,
        BenchmarkInfo,
        CancelSignal,
        ScoringRun;
