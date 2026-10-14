/// Engine SPI of flutter_edge_ai: everything an engine, backend, tokenizer,
/// resolver or skill-executor package needs, in one web-safe import. Re-exports
/// the app library (`flutter_edge_ai.dart`).
///
/// Native-only helpers (`dart:io` / `dart:ffi`) are in `engine_io.dart`,
/// web-only ones (`dart:js_interop`) in `engine_web.dart`. Nothing under
/// `lib/src` is public: import these libraries, never a `src/` path.
///
/// The namespace is pinned by the symbol golden in `test/public_surface/`.
library;

export 'flutter_edge_ai.dart';

// Registries engines consult.
export 'src/registry/embedding_tokenizer_registry.dart'
    show EmbeddingTokenizerRegistry;
export 'src/registry/skill_executor_registry.dart' show SkillExecutorRegistry;
export 'src/registry/hugging_face_resolver_source.dart'
    show HuggingFaceResolverSource;
export 'src/registry/runtime_config.dart' show RuntimeConfig;

// Lifecycle and logging.
export 'src/lifecycle/close_notifier.dart' show CloseNotifier;
export 'src/utils/edge_ai_log.dart' show edgeAiLog, edgeAiLogLevel;

// File naming (top-level functions over FileNameUtils, which stays internal).
export 'src/utils/file_names.dart' show isLiteRtLmFilename, sanitizeHfDirName;

// Media sniffing for LLM web arms (sniffEncodedMediaFormat is in the app
// library). Pure Dart, so it is web-safe and lives here rather than in
// engine_web.dart.
export 'src/media/encoded_media_format.dart' show detectImageMimeType;

// Inference-engine helpers. (`supportedLoraRanks` and
// `defaultMaxFunctionBufferLength` reach engines through the app library.)
export 'src/extensions.dart' show MessageExtension;
export 'src/parsing/sdk_response_parser.dart' show SdkResponseParser;
export 'src/parsing/sdk_text_extractor.dart' show SdkTextExtractor;
export 'src/parsing/tool_calls_of.dart' show toolCallsOf;
export 'src/model_management/model_specs.dart' show TtsModelTypeManifest;

// Embedding SPI. Core builds, hosts and closes every embedding model from
// what a backend's describe() returns; CommonEmbeddingModel, the hosts and the
// embedder cache stay internal.
export 'src/embedding/embedding_pass.dart'
    show EmbeddingPass, EmbeddingPassDescriptor, EmbeddingPassInfo;
export 'src/embedding/token_embedding_pass.dart'
    show TokenEmbeddingPass, TokenPassGraph;
export 'src/embedding/forward_result.dart'
    show EmbeddingOutputContract, ForwardResult, finalizeEmbedding;
export 'src/embedding/pooling.dart' show meanPoolAndNormalize;
export 'src/embedding/tokenizer_adapter.dart'
    show EmbeddingTokenizer, EmbeddingTokenizerFactory, TokenizedInput;
