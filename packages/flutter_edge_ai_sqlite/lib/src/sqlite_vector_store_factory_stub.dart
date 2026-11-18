import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import 'sqlite_text_tokenizer.dart';

const bool isSupported = false;

VectorStoreRepository createStore({
  required bool enableTextSearch,
  SqliteTextTokenizer? textTokenizer,
}) => throw UnsupportedError(
  'SQLite vector storage is not available on this platform.',
);
