/// SQLite vector search (sqlite-vec / vec0) on-device RAG vector store for
/// Flutter Edge AI RAG.
///
/// Opt-in package. Register [SqliteVectorStoreProvider] with
/// `FlutterEdgeAiRag`; it selects the native or web implementation:
///
/// ```dart
/// import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
/// import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
///
/// final rag = FlutterEdgeAiRag(
///   providers: [const SqliteVectorStoreProvider()],
/// );
/// ```
library;

export 'src/sqlite_vector_store_provider.dart';

export 'src/sqlite_vector_store_stub.dart'
    if (dart.library.ffi) 'src/sqlite_vector_store.dart';

export 'src/web_sqlite_vector_store_stub.dart'
    if (dart.library.js_interop) 'src/web_sqlite_vector_store.dart';
