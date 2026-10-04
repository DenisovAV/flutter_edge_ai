/// qdrant-edge on-device RAG vector store for flutter_edge_ai_rag (native FFI).
///
/// Opt-in package, native platforms only. Register its provider with an
/// instance-scoped `FlutterEdgeAiRag`:
///
/// ```dart
/// import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
/// import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
///
/// final rag = FlutterEdgeAiRag(
///   providers: [QdrantVectorStoreProvider()],
/// );
/// ```
library;

export 'src/qdrant_vector_store_stub.dart'
    if (dart.library.ffi) 'src/qdrant_vector_store.dart';

/// `QdrantLegacyStoreException` is exported from the real arm above. Catch it —
/// not the base `VectorStoreException` — before calling `clear()`: it is the
/// only failure whose documented remedy is destructive.
