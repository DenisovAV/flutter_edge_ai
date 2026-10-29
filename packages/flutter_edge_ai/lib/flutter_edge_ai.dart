/// The app library of flutter_edge_ai: everything an application needs to
/// install models and run inference, embeddings and speech.
///
/// Engine, backend, tokenizer, resolver and skill-executor packages import
/// `package:flutter_edge_ai/engine.dart` instead (it re-exports this library);
/// native-only helpers live in `engine_io.dart`, web-only ones in
/// `engine_web.dart`. Nothing under `lib/src` is public.
///
/// Every export carries an explicit `show` list, and the namespace is pinned by
/// the symbol golden in `test/public_surface/`.
library;

export 'src/interface.dart'
    show
        FlutterEdgeAiPlugin,
        InferenceModel,
        InferenceModelSession,
        RawSdkResponseSession,
        SessionMetrics,
        SpeechRecognizer,
        SpeechSynthesizer,
        supportedLoraRanks;
export 'src/model_file_manager_interface.dart'
    show ModelFileManager, ModelReplacePolicy;

// Public parameter types that exported APIs require.
export 'src/domain/model_source.dart'
    show AssetSource, BundledSource, FileSource, ModelSource, NetworkSource;
export 'src/services/file_system_service.dart'
    show FileSystemService; // custom-storage hook accepted by initialize()

// The provider contracts FlutterEdgeAi.initialize accepts. Engine packages
// implement them; apps only pass instances in.
export 'src/registry/inference_engine_provider.dart'
    show InferenceEngineProvider;
export 'src/registry/embedding_backend_provider.dart'
    show EmbeddingBackendProvider;
export 'src/registry/embedding_tokenizer_provider.dart'
    show EmbeddingTokenizerProvider;
export 'src/registry/stt_backend_provider.dart' show SttBackendProvider;
export 'src/registry/tts_backend_provider.dart' show TtsBackendProvider;
export 'src/registry/skill_executor_provider.dart' show SkillExecutorProvider;
// Hugging Face manifest-resolver seam: the contract initialize() accepts plus
// the value types FlutterEdgeAi.resolveHuggingFace returns.
export 'src/registry/hugging_face_resolver.dart'
    show
        HuggingFaceResolver,
        ModelRuntimeDefaults,
        ResolvedHfFile,
        ResolvedHfModel;

export 'src/domain/platform_types.dart'
    show ActivationDataType, PreferredBackend;
export 'src/domain/multimodal_order.dart' show MediaPosition, MultimodalOrder;
export 'src/domain/no_active_model_error.dart' show NoActiveModelError;

// Embedding inputs, task types and failures.
export 'src/embedding/embedding_modality.dart' show EmbeddingModality;
export 'src/embedding/embedding_input.dart' show EmbeddingInput;
export 'src/embedding/embedding_model.dart' show EmbeddingModel;
export 'src/embedding/task_type.dart' show TaskType;
export 'src/embedding/embedding_exceptions.dart'
    show
        EmbedderCloseTimeoutException,
        EmbedderClosedException,
        EmbeddingCancelledException,
        EmbeddingEngineException,
        EmbeddingException,
        EmbeddingFormatNotSupportedException,
        EmbeddingInputTooLongException,
        EmbeddingLoadException,
        EmbeddingModalityNotLoadedException,
        UnsupportedEmbeddingCombinationException;
// Deciders (experimental): pick one of N options for an input, or abstain.
export 'src/decision/decider.dart'
    show
        AbstainReason,
        AbstainSignalKind,
        Decider,
        DeciderAnswer,
        DeciderCapabilities,
        DeciderInput,
        DeciderProvenance,
        DeciderQuestionType,
        DeciderRequest,
        RankedOption,
        ScoreKind;
export 'src/decision/decider_exceptions.dart'
    show
        DeciderCancelledException,
        DeciderException,
        DeciderSpaceMismatchException,
        DeciderUnsupportedException;
export 'src/decision/decider_method.dart'
    show
        DeciderMethod,
        EmbeddingDeciderCalibration,
        InferenceDeciderCalibration;
export 'src/decision/decider_option.dart' show DeciderOption;
export 'src/media/encoded_media_format.dart'
    show EncodedMediaFormat, sniffEncodedMediaFormat;
export 'src/message.dart' show Message, MessageType;
export 'src/model.dart' show ModelFileType, ModelType;
// Sampling a session asks for, and the fully resolved set an engine sends.
export 'src/sampling.dart' show ResolvedSampling, SamplingParams;
export 'src/model_response.dart'
    show
        FunctionCallResponse,
        ModelResponse,
        ParallelFunctionCallResponse,
        TextResponse,
        ThinkingResponse;
export 'src/function_call_parser.dart' show FunctionCallParser;
export 'src/tool.dart' show Tool, ToolChoice;
export 'src/utils/edge_ai_log.dart' show EdgeAiLogLevel;
export 'src/chat.dart' show InferenceChat, defaultMaxFunctionBufferLength;
export 'src/extensions.dart' show ModelThinkingFilter;
export 'src/model_management/cancel_token.dart'
    show CancelToken, DownloadCancelledException;

// Image processing utilities (prevent AI image corruption).
export 'src/image_processor.dart'
    show ImageProcessingException, ImageProcessor, ProcessedImage;
export 'src/image_tokenizer.dart'
    show ImageTokenizationException, ImageTokenizer;
export 'src/vision_encoder_validator.dart'
    show
        EstimatedDimensions,
        Gemma3Specs,
        GeneralVisionSpecs,
        ValidationResult,
        VisionEncoderType,
        VisionEncoderValidationException,
        VisionEncoderValidator,
        VisionSpecs;
export 'src/image_error_handler.dart'
    show
        CorruptionAction,
        CorruptionDetectionResult,
        ErrorHandlingResult,
        ErrorType,
        ImageErrorHandler;
export 'src/multimodal_image_handler.dart'
    show
        DiagnosticReport,
        MultimodalImageHandler,
        MultimodalImageResult,
        ResponseAction,
        ResponseValidationResult;

// Modern API.
export 'src/api/flutter_edge_ai.dart' show FlutterEdgeAi;
export 'src/api/inference_installation_builder.dart'
    show InferenceInstallation, InferenceInstallationBuilder;
export 'src/api/embedding_installation_builder.dart'
    show EmbeddingInstallation, EmbeddingInstallationBuilder;
export 'src/api/stt_installation_builder.dart'
    show SttInstallation, SttInstallationBuilder;
export 'src/api/tts_installation_builder.dart'
    show TtsInstallation, TtsInstallationBuilder;

// Model catalog: the models the registered packages offer, pinned files.
export 'src/catalog/model_artifact.dart' show ModelArtifact;
export 'src/catalog/npu_target.dart' show NpuTarget, NpuVendor;
export 'src/catalog/model_catalog.dart'
    show
        CatalogModel,
        CatalogVariant,
        EmbedderVariant,
        InferenceVariant,
        ModelCatalog,
        ModelCatalogSource,
        SttVariant,
        TtsVariant;

// Web storage mode.
export 'src/domain/web_storage_mode.dart' show WebStorageMode;

// Download error types (401/403 gated models, etc.).
export 'src/domain/download_error.dart'
    show
        CanceledError,
        DownloadError,
        ForbiddenError,
        NetworkError,
        NotFoundError,
        RateLimitedError,
        ServerError,
        UnauthorizedError,
        UnknownError;
export 'src/domain/download_exception.dart'
    show DownloadErrorMessage, DownloadException;

// Model specs. These dart:io-free value types live in their own library so
// the public API doesn't pull the mobile implementation (and its dart:io)
// into the web/wasm graph.
export 'src/model_management/model_specs.dart'
    show
        // Model specifications
        InferenceModelSpec,
        EmbeddingModelSpec,
        SttModelSpec,
        SttModelType,
        TtsModelSpec,
        TtsModelType,
        ModelSpec,
        ModelFile,
        // Download progress
        DownloadProgress,
        // Storage info
        StorageStats,
        OrphanedFileInfo,
        // Model management types
        ModelManagementType,
        // Exceptions
        ModelStorageException,
        ModelValidationException;

// Desktop implementation (conditionally — only on non-web platforms). The
// pubspec's `dartPluginClass: FlutterEdgeAiDesktop` resolves through this
// library, so it must stay exported here.
export 'src/desktop/flutter_edge_ai_desktop.dart'
    if (dart.library.js_interop) 'src/desktop/flutter_edge_ai_desktop_stub.dart'
    show FlutterEdgeAiDesktop, isDesktop;
