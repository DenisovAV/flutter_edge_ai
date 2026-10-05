/// SQLite vector search (sqlite-vec / vec0) on-device RAG vector store for
/// flutter_gemma.
///
/// Opt-in package. Add it to pubspec.yaml and pass an instance to
/// `FlutterGemma.initialize(vectorStore: ...)`:
///
/// ```dart
/// import 'package:flutter_gemma/flutter_gemma.dart';
/// import 'package:flutter_gemma_rag_sqlite/flutter_gemma_rag_sqlite.dart';
///
/// await FlutterGemma.initialize(
///   vectorStore: kIsWeb ? WebSqliteVectorStore() : SqliteVectorStore(),
/// );
/// ```
library;

export 'src/sqlite_vector_store_stub.dart'
    if (dart.library.ffi) 'src/sqlite_vector_store.dart';

export 'src/web_sqlite_vector_store_stub.dart'
    if (dart.library.js_interop) 'src/web_sqlite_vector_store.dart';
