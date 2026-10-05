export 'flutter_gemma_interface.dart';
export 'model_file_manager_interface.dart';

// Public parameter types that exported APIs require — previously forced
// consumers into deep `core/` imports.
export 'core/domain/model_source.dart'; // ModelSource sealed type — required by InferenceModelSpec / withLora / deleteModel
export 'core/services/file_system_service.dart'
    show FileSystemService; // custom-storage hook accepted by initialize()

// Vector store filter DSL — passed to searchSimilar to constrain results
// by payload. Honored on every native platform (qdrant-edge); silently
// ignored on Web.
// The embedding seam: contracts an engine implements, the worker that runs
// them off the UI isolate, and the facade it produces. Contracts only — the
// tokenizer IMPLEMENTATIONS stay in flutter_gemma_embeddings, which core never
// depends on (see "Packages -> core, never to each other" in CLAUDE.md).
export 'core/registry/embedding_tokenizer_provider.dart';
export 'core/registry/embedding_tokenizer_registry.dart';
export 'core/embedding/forward_pass.dart';
export 'core/embedding/tokenizer_adapter.dart';
export 'core/embedding/pooling.dart';
// Real arm by default, web overrides -- core's own convention everywhere else
// (flutter_gemma_interface.dart, service_registry.dart). The worker needs
// dart:isolate; web engine arms build their own EmbeddingModel and never
// reach it.
export 'core/embedding/common_embedding_model.dart'
    if (dart.library.js_interop) 'core/embedding/common_embedding_model_stub.dart';

export 'core/services/vector_store_filter.dart';
export 'core/services/vector_store_repository.dart'; // VectorStoreRepository + VectorStoreException for opt-in RAG packages
// Agentic skill-executor seam — the opt-in flutter_gemma_agent package's
// SkillExecutor implements this contract and is registered/resolved here.
export 'core/registry/skill_executor_provider.dart'; // SkillExecutorProvider contract
export 'core/registry/skill_executor_registry.dart'; // SkillExecutorRegistry (fromModel reads it)
// Hugging Face manifest-resolver seam. Only the app-facing value types are
// re-exported — [ResolvedHfModel] (plus its directory members [ResolvedHfFile])
// and [ModelRuntimeDefaults] are the result of FlutterGemma.resolveHuggingFace.
// The [HuggingFaceResolver] contract itself is implemented by engine packages,
// which import it directly from core/registry/hugging_face_resolver.dart — as
// they do the inference / embedding / stt / tts *Provider contracts (those are
// not barrel-exported either; skill_executor_provider above is the lone
// exception).
export 'core/registry/hugging_face_resolver.dart'
    show ResolvedHfModel, ResolvedHfFile, ModelRuntimeDefaults;
export 'core/domain/platform_types.dart'; // PreferredBackend + RAG value types
export 'core/message.dart';
export 'core/model.dart'; // Export ModelType and other model-related classes
export 'core/model_response.dart';
export 'core/function_call_parser.dart';
export 'core/tool.dart';
export 'core/utils/gemma_log.dart' show GemmaLogLevel;
export 'core/chat.dart';
export 'core/model_management/cancel_token.dart';

// Export image processing utilities to prevent AI image corruption
export 'core/image_processor.dart';
export 'core/image_tokenizer.dart' hide ModelType;
export 'core/vision_encoder_validator.dart';
export 'core/image_error_handler.dart';
export 'core/multimodal_image_handler.dart';

// Export Modern API
export 'core/api/flutter_gemma.dart';
export 'core/api/inference_installation_builder.dart';
export 'core/api/embedding_installation_builder.dart';
export 'core/api/stt_installation_builder.dart';
export 'core/api/tts_installation_builder.dart';

// Export Web-specific types
export 'core/domain/web_storage_mode.dart';

// Download error types (401/403 gated models, etc.)
export 'core/domain/download_error.dart';
export 'core/domain/download_exception.dart';

// Export Model Specs (needed for advanced use cases). These dart:io-free value
// types live in their own library so the public API doesn't pull the mobile
// implementation (and its dart:io) into the web/wasm graph.
export 'core/model_management/model_specs.dart'
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
        ModelStorageException;

// Export Desktop implementation (conditionally - only on non-web platforms)
// Note: Desktop uses MobileModelManager for file management
export 'desktop/flutter_gemma_desktop.dart'
    if (dart.library.js_interop) 'desktop/flutter_gemma_desktop_stub.dart'
    show FlutterGemmaDesktop, isDesktop;

// ModelReplacePolicy is already exported from model_file_manager_interface.dart
