@TestOn('browser')
library;

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web provider declines without loading qdrant native code', () async {
    const provider = QdrantVectorStoreProvider();
    final spec = VectorStoreSpec(
      providerId: 'qdrant',
      location: 'unused-on-web',
    );

    expect(provider.canHandle(spec), isFalse);
    await expectLater(
      provider.createStore(spec),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
