import 'dart:io';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';

import 'sqlite_vector_store.dart';

bool get isSupported =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isMacOS ||
    Platform.isWindows ||
    Platform.isLinux;

VectorStoreRepository createStore() => SqliteVectorStore();
