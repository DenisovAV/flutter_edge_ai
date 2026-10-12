/// Pluggable on-device RAG for Flutter Edge AI: independent vector-store
/// providers, embedders and indexes.
///
/// Re-exports the core embedding types RAG code needs, so vector-store
/// packages import only this library.
library;

export 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show
        EmbedderCloseTimeoutException,
        EmbedderClosedException,
        EmbeddingCancelledException,
        EmbeddingEngineException,
        EmbeddingException,
        EmbeddingFormatNotSupportedException,
        EmbeddingInput,
        EmbeddingInputTooLongException,
        EmbeddingLoadException,
        EmbeddingModalityNotLoadedException,
        EmbeddingModality,
        TaskType,
        UnsupportedEmbeddingCombinationException;

export 'src/embedding.dart';
export 'src/filter.dart';
export 'src/flutter_edge_ai_rag.dart';
export 'src/logging.dart';
export 'src/rag_index.dart' show RagIndex;
export 'src/vector_store.dart';
export 'src/vector_store_provider.dart';
