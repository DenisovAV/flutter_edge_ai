// A file-path lookup that FAILS is not "not installed" (the no-error-hiding
// rule): the embedder load surfaces the lookup's own error, so a broken
// repository is not reported as a missing model.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _RepositoryDown implements Exception {
  const _RepositoryDown();
  @override
  String toString() => 'repository is down';
}

/// In memory, and throws from every lookup while [down].
final class _FlakyRepository implements repo.ModelRepository {
  final _models = <String, repo.ModelInfo>{};
  bool down = false;

  void _check() {
    if (down) throw const _RepositoryDown();
  }

  @override
  Future<void> saveModel(repo.ModelInfo info) async => _models[info.id] = info;

  @override
  Future<repo.ModelInfo?> loadModel(String id) async {
    _check();
    return _models[id];
  }

  @override
  Future<void> deleteModel(String id) async => _models.remove(id);

  @override
  Future<List<repo.ModelInfo>> listInstalled() async {
    _check();
    return _models.values.toList();
  }

  @override
  Future<bool> isInstalled(String id) async {
    _check();
    return _models.containsKey(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _FlakyRepository repository;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('emb_lookup_');
    PathProviderPlatform.instance = _FixedPathProvider(dir.path);
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    repository = _FlakyRepository();
    await ServiceRegistry.initialize(modelRepository: repository);
    EmbeddingRegistry.instance.reset();
  });

  tearDown(() async {
    ServiceRegistry.reset();
    EmbeddingRegistry.instance.reset();
    await dir.delete(recursive: true);
  });

  test(
    'a lookup that throws surfaces its error, not "not installed"',
    () async {
      final model = File('${dir.path}/m.tflite')
        ..writeAsBytesSync(Uint8List(1024 * 1024 + 16));
      final tokenizer = File('${dir.path}/t.json')
        ..writeAsBytesSync(Uint8List(2048));
      final spec = EmbeddingModelSpec(
        name: 'm',
        modelSource: FileSource(model.path),
        tokenizerSource: FileSource(tokenizer.path),
      );
      for (final f in spec.files) {
        await repository.saveModel(
          repo.ModelInfo(
            id: f.filename,
            source: f.source,
            installedAt: DateTime(2026),
            sizeBytes: 1,
            type: repo.ModelType.embedding,
            hasLoraWeights: false,
          ),
        );
      }
      final plugin = FlutterEdgeAiMobile();
      await plugin.modelManager.activateInstalledModel(spec);

      repository.down = true;
      await expectLater(
        plugin.createEmbeddingModel(),
        throwsA(isA<_RepositoryDown>()),
      );
    },
  );
}

final class _FixedPathProvider extends PathProviderPlatform {
  _FixedPathProvider(this._path);

  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;

  @override
  Future<String?> getApplicationSupportPath() async => _path;

  @override
  Future<String?> getTemporaryPath() async => _path;
}
