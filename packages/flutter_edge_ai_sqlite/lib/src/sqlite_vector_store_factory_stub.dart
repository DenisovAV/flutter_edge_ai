import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

const bool isSupported = false;

VectorStoreRepository createStore() => throw UnsupportedError(
  'SQLite vector storage is not available on this platform.',
);
