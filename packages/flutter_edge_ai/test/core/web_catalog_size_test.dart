@TestOn('browser')
library;

// On the web, in the default storage (WebStorageMode.cacheApi), an install
// whose file is over 2 GiB is refused before it downloads.
//
// Run: flutter test --platform chrome test/core/web_catalog_size_test.dart

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog/catalog_fixtures.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    await ServiceRegistry.initialize();
  });
  tearDown(ServiceRegistry.reset);

  test('a catalog LLM over 2 GiB names WebStorageMode.streaming', () async {
    final variant = TestLlm(
      'big',
      file: artifact('big.litertlm', size: 3000000000),
    );
    await expectLater(
      FlutterEdgeAi.installModelFromCatalog(variant).install(),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('WebStorageMode.streaming'),
        ),
      ),
    );
  });

  test('a catalog embedder over 2 GiB too', () async {
    final variant = TestEmbedder(
      model: artifact('big.litertlm', size: 3000000000),
    );
    await expectLater(
      FlutterEdgeAi.installEmbedder().fromCatalog(variant).install(),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('WebStorageMode.streaming'),
        ),
      ),
    );
  });

  test('a catalog STT model over 2 GiB too', () async {
    await expectLater(
      FlutterEdgeAi.installStt()
          .fromCatalog(TestStt(modelSize: 3000000000))
          .install(),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('WebStorageMode.streaming'),
        ),
      ),
    );
  });

  test('a size is accepted on the web, and not checked', () {
    FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromNetwork('https://example.com/m.litertlm', expectedSize: 5);
  });
}
