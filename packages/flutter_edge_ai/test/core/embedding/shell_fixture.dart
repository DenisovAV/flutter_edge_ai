// What the shell-level embedder tests share: a real ServiceRegistry over temp
// directories, and a way to make a model the ACTIVE embedder of one shell —
// since 2.3.0 createEmbeddingModel takes no paths, it builds the active one.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/desktop/flutter_edge_ai_desktop.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_edge_ai/src/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two shells a VM test can construct. Web is absent because
/// `FlutterEdgeAiWeb` needs `dart:js_interop`; it calls the same
/// `loadActiveEmbedder` inside the same `EmbedderCache.serialize`.
final shells = <({String name, FlutterEdgeAiPlugin Function() create})>[
  (name: 'mobile', create: FlutterEdgeAiMobile.new),
  (name: 'desktop', create: () => FlutterEdgeAiDesktop.instance),
];

/// Temp directories, a path provider over them, empty preferences and an
/// initialised ServiceRegistry. Call from `setUp`; [tearDownShellFixture]
/// from `tearDown`.
final class ShellFixture {
  late Directory _root;

  Future<void> setUp() async {
    _root = await Directory.systemTemp.createTemp('emb_shell_');
    final documents = Directory('${_root.path}/docs')..createSync();
    final support = Directory('${_root.path}/support')..createSync();
    Directory('${_root.path}/src').createSync();
    PathProviderPlatform.instance = _FixedPathProvider(
      documents.path,
      support.path,
    );
    SharedPreferences.setMockInitialValues({});
    ServiceRegistry.reset();
    await ServiceRegistry.initialize();
  }

  Future<void> tearDown() async {
    // FlutterEdgeAiDesktop.instance is a process singleton: forget what this
    // test made active there, in memory and in preferences.
    final desktop = FlutterEdgeAiDesktop.instance;
    await desktop.initializedEmbeddingModel?.close();
    desktop.modelManager.clearModelCache();
    await desktop.modelManager.clearActiveEmbeddingIdentity();
    ServiceRegistry.reset();
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  }

  /// A file of [bytes] bytes under the fixture's source directory.
  String file(String name, int bytes) {
    final path = '${_root.path}/src/$name';
    final f = File(path);
    if (!f.existsSync()) f.writeAsBytesSync(Uint8List(bytes));
    return path;
  }

  /// Installs `<model>` (and `<tokenizer>`, unless the model is a
  /// `.litertlm` bundle) from temp files and makes it [plugin]'s active
  /// embedder. Returns the spec; its model path is
  /// `<fixture>/src/<model>`.
  Future<EmbeddingModelSpec> activate(
    FlutterEdgeAiPlugin plugin, {
    required String model,
    String? tokenizer,
  }) async {
    // Above FileSourceHandler's floors: 1 MB for models, 1 KB for .json/.model.
    final modelPath = file(model, 1024 * 1024 + 16);
    final tokenizerPath = tokenizer == null ? null : file(tokenizer, 2048);
    final spec = EmbeddingModelSpec(
      name: model,
      modelSource: FileSource(modelPath),
      tokenizerSource: tokenizerPath == null ? null : FileSource(tokenizerPath),
    );
    final repository = ServiceRegistry.instance.modelRepository;
    for (final f in spec.files) {
      await repository.saveModel(
        repo.ModelInfo(
          id: f.filename,
          source: f.source,
          installedAt: DateTime(2026),
          sizeBytes: 1024,
          type: repo.ModelType.embedding,
          hasLoraWeights: false,
        ),
      );
    }
    await (plugin.modelManager as MobileModelManager).activateInstalledModel(
      spec,
    );
    return spec;
  }

  /// The model path the shell resolves for [model].
  String modelPath(String model) => '${_root.path}/src/$model';
}

final class _FixedPathProvider extends PathProviderPlatform {
  _FixedPathProvider(this._documents, this._support);

  final String _documents;
  final String _support;

  @override
  Future<String?> getApplicationDocumentsPath() async => _documents;

  @override
  Future<String?> getApplicationSupportPath() async => _support;

  @override
  Future<String?> getTemporaryPath() async => _support;
}
