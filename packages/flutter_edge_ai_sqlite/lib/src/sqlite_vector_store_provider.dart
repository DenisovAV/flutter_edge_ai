import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import 'sqlite_vector_store_factory_stub.dart'
    if (dart.library.ffi) 'sqlite_vector_store_factory_native.dart'
    if (dart.library.js_interop) 'sqlite_vector_store_factory_web.dart'
    as platform;

/// Creates the platform-appropriate SQLite + sqlite-vec vector store.
///
/// Applications register this provider once; native platforms receive
/// `SqliteVectorStore` and web receives `WebSqliteVectorStore` without an
/// application-level `kIsWeb` branch.
class SqliteVectorStoreProvider implements VectorStoreProvider {
  const SqliteVectorStoreProvider({this.priority = 0});

  static const String providerId = 'sqlite';

  @override
  String get id => providerId;

  @override
  String get name => 'SQLite + sqlite-vec';

  @override
  final int priority;

  @override
  bool canHandle(VectorStoreSpec spec) =>
      spec.providerId == providerId && platform.isSupported;

  @override
  Future<VectorStoreRepository> createStore(VectorStoreSpec spec) async {
    if (!canHandle(spec)) {
      throw UnsupportedError(
        'SQLite vector storage is unavailable on this platform or the '
        'providerId is not "$providerId".',
      );
    }
    return platform.createStore();
  }
}
