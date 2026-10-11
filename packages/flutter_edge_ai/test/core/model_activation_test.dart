// isInstalledFrom: when an installer may skip a file because its repository
// record says it is already installed from the requested source.
//
// Run: flutter test test/core/model_activation_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/model_activation.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File picked;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    await ServiceRegistry.initialize();
    dir = await Directory.systemTemp.createTemp('fe_activation_');
    picked = File('${dir.path}/model.task')..writeAsStringSync('x');
  });

  tearDown(() async {
    ServiceRegistry.reset();
    await dir.delete(recursive: true);
  });

  ModelInfo recordOf(ModelSource source) => ModelInfo(
    id: 'model.task',
    source: source,
    installedAt: DateTime(2026),
    sizeBytes: 1,
    type: ModelType.inference,
    hasLoraWeights: false,
  );

  final download = NetworkSource('https://example.com/model.task');

  test('nothing recorded is not installed', () async {
    expect(await isInstalledFrom(null, download), isFalse);
    expect(await isInstalledFrom(null, FileSource(picked.path)), isFalse);
  });

  test('a download is installed whenever its name is', () async {
    expect(await isInstalledFrom(recordOf(download), download), isTrue);
    expect(
      await isInstalledFrom(
        recordOf(download),
        NetworkSource('https://mirror.example.com/model.task'),
      ),
      isTrue,
      reason: 'another URL does not download the model again',
    );
    expect(
      await isInstalledFrom(recordOf(FileSource(picked.path)), download),
      isTrue,
    );
  });

  test('the app\'s file is installed from its own path while it is there', () {
    expect(
      isInstalledFrom(
        recordOf(FileSource(picked.path)),
        FileSource(picked.path),
      ),
      completion(isTrue),
    );
  });

  test('the app\'s file picked from another path is not', () async {
    expect(
      await isInstalledFrom(
        recordOf(FileSource('${dir.path}/old/model.task')),
        FileSource(picked.path),
      ),
      isFalse,
    );
    expect(
      await isInstalledFrom(recordOf(download), FileSource(picked.path)),
      isFalse,
      reason: 'a download replaced by the app\'s file',
    );
  });

  test('the app\'s file that is gone is not', () async {
    picked.deleteSync();
    expect(
      await isInstalledFrom(
        recordOf(FileSource(picked.path)),
        FileSource(picked.path),
      ),
      isFalse,
    );
  });
}
