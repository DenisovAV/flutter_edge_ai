import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import 'web_sqlite_vector_store.dart';

const bool isSupported = true;

VectorStoreRepository createStore() => WebSqliteVectorStore();
