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
    'replacement prunes only the demo-owned copy and keeps external files',
    () async {
      final source = File('${scratch.path}/source.gguf');
      await source.writeAsString('first');
      final previous = File(await importModel(source.path));
      final replacement = File(await importModel(source.path));
      await pruneImportedModels(replacement.path);
      expect(await previous.exists(), isFalse);
      expect(await replacement.readAsString(), 'first');
      expect(await source.exists(), isTrue);
      await pruneImportedModels(source.path);
      expect(await replacement.exists(), isTrue);
    },
  );

  test(
    'temporary picker move avoids leaving a duplicate and preserves symlinks',
    () => IOOverrides.runZoned(() async {
      final inbox = Directory('${scratch.path}/app/tmp/dev.llamadart-Inbox');
      await inbox.create(recursive: true);
      final external = File('${scratch.path}/external.gguf');
      await external.writeAsString('owned bytes');
      final link = Link('${inbox.path}/linked.gguf');
      await link.create(external.path);
      final imported = File(
        await importModel(link.path, cleanupPickerInbox: true),
      );
      expect(await imported.readAsString(), 'owned bytes');
      expect(await link.exists(), isTrue);
      expect(await external.exists(), isTrue);
      final otherInbox = Directory('${scratch.path}/external-Inbox');
      await otherInbox.create();
      final other = File('${otherInbox.path}/other.gguf');
      await other.writeAsString('external');
      await removePickerInboxCopy(other.path);
      expect(await other.exists(), isTrue);
    }, getSystemTempDirectory: () => Directory('${scratch.path}/app/tmp')),
  );

  test(
    'iOS tmp differs from path_provider caches and only owned Inbox is moved',
    () => IOOverrides.runZoned(() async {
      final inbox = Directory('${scratch.path}/app/tmp/dev.llamadart-Inbox');
      await inbox.create(recursive: true);
      final source = File('${inbox.path}/picked.gguf');
      await source.writeAsString('model');
      final imported = File(
        await importModel(source.path, cleanupPickerInbox: true),
      );
      expect(await imported.readAsString(), 'model');
      expect(await source.exists(), isFalse);
      final external = File('${scratch.path}/external.gguf');
      await external.writeAsString('external');
      final link = Link('${inbox.path}/linked.gguf');
      await link.create(external.path);
      await removePickerInboxCopy(link.path);
      await removePickerInboxCopy(external.path);
      expect(await external.exists(), isTrue);
      expect(await link.exists(), isTrue);
    }, getSystemTempDirectory: () => Directory('${scratch.path}/app/tmp')),
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
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/Documents';
  @override
  Future<String?> getTemporaryPath() async => '$root/Library/Caches';
}
