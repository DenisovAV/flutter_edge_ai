import 'dart:io';

import 'package:flutter_edge_ai_llama_demo/model_import_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late PathProviderPlatform original;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('gguf-import-test-');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths('${scratch.path}/app');
  });
  tearDown(() async {
    PathProviderPlatform.instance = original;
    await scratch.delete(recursive: true);
  });

  test(
    'picker import survives loss of the external source and keeps its bytes',
    () async {
      final source = File('${scratch.path}/source.gguf');
      await source.writeAsBytes(
        List.generate(1024 * 1024, (index) => index % 256),
      );
      final imported = File(await importModel(source.path));
      expect(imported.path, startsWith('${scratch.path}/app/gguf_lab/'));
      expect(await imported.readAsBytes(), await source.readAsBytes());
      await source.delete();
      expect(await imported.length(), 1024 * 1024);
    },
  );

  test(
    'failed imports leave no partial model and reject unrelated formats',
    () async {
      await expectLater(
        importModel('${scratch.path}/missing.gguf'),
        throwsA(isA<FileSystemException>()),
      );
      final unrelated = File('${scratch.path}/model.task');
      await unrelated.writeAsString('wrong format');
      await expectLater(importModel(unrelated.path), throwsArgumentError);
      expect(
        await Directory('${scratch.path}/app/gguf_lab').list().toList(),
        isEmpty,
      );
    },
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}
