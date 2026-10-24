/// GGUF inference and embedding connector for Flutter Edge AI.
///
/// Register [LlamaEngineProvider] and use core's model/chat/session contracts.
library;

export 'src/llama_engine_provider.dart'
    show LlamaEngineProvider, LlamaProjectorResolver;

export 'src/llama_embedding_backend.dart' show LlamaEmbeddingBackend;
