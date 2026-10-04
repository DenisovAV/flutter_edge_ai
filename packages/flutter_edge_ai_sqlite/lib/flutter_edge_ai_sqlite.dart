/// SQLite vector search (sqlite-vec / vec0) on-device RAG vector store for
/// flutter_edge_ai.
///
/// Opt-in package. Add it to pubspec.yaml and pass an instance to
/// `FlutterEdgeAi.initialize(vectorStore: ...)`:
///
/// ```dart
/// import 'package:flutter_edge_ai/flutter_edge_ai.dart';
/// import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
///
/// await FlutterEdgeAi.initialize(
///   vectorStore: kIsWeb ? WebSqliteVectorStore() : SqliteVectorStore(),
/// );
/// ```
library;

export 'src/sqlite_vector_store_stub.dart'
    if (dart.library.ffi) 'src/sqlite_vector_store.dart';

export 'src/web_sqlite_vector_store_stub.dart'
    if (dart.library.js_interop) 'src/web_sqlite_vector_store.dart';
