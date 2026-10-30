import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show FlutterEdgeAiPlugin;
import 'package:flutter_edge_ai/src/catalog/model_catalog.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model.dart' show ModelFileType;
import 'package:flutter_edge_ai/src/model_file_manager_interface.dart';
import 'package:flutter_edge_ai/src/model_management/install_rule.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/services/file_system_service.dart';
import 'package:flutter_edge_ai/src/utils/file_name_utils.dart';
import 'package:meta/meta.dart' show visibleForTesting;

final _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');
final _commit = RegExp(r'^[0-9a-f]{40}$');

/// What an installed file should be: the `expectedSize` an installation
/// builder was given for it. `const FileExpectation()` is the empty one:
/// nothing to check.
final class FileExpectation {
  /// An expectation; see [FileExpectation.checked] for one from a caller.
  const FileExpectation({this.size});

  /// [size] as a caller passed it, refused before anything downloads when it
  /// cannot be right (negative).
  factory FileExpectation.checked({int? size}) {
    if (size != null && size < 0) {
      throw ArgumentError.value(size, 'expectedSize', 'must not be negative');
    }
    return FileExpectation(size: size);
  }

  /// Bytes, exactly.
  final int? size;

  /// Whether there is anything to check.
  bool get isEmpty => size == null;
}

/// The largest file the web's default storage, the Cache API, holds: a file
/// is read whole into one `ArrayBuffer`, which browsers cap near 2 GiB.
const webCacheLimitBytes = 2 * 1024 * 1024 * 1024;

/// Refuses, before anything is downloaded, a file whose expected size is over
/// [webCacheLimitBytes] on the web in any storage mode but streaming (the
/// default `WebStorageMode.cacheApi`, and `none`): the download would fail
/// part-way. `WebStorageMode.streaming` (OPFS) holds
/// it. [web] and [streaming] replace the runtime's answers in tests.
void refuseTooLargeForWebCache(
  Map<String, FileExpectation> expected, {
  bool? web,
  bool? streaming,
}) {
  if (!(web ?? kIsWeb)) return;
  if (streaming ?? ServiceRegistry.instance.useStreamingStorage) return;
  final tooLarge = [
    for (final MapEntry(key: name, value: e) in expected.entries)
      if ((e.size ?? 0) > webCacheLimitBytes) name,
  ];
  if (tooLarge.isEmpty) return;
  throw UnsupportedError(
    '${tooLarge.join(', ')} is over 2 GiB, more than this web storage mode '
    'holds; only WebStorageMode.streaming does. Pass '
    'webStorageMode: WebStorageMode.streaming to FlutterEdgeAi.initialize.',
  );
}

/// The active model of every kind, read before an install changes any: a
/// file name is one file, whichever kind of model reads it.
List<ModelSpec> activeModelsOf(ModelFileManager manager) => [
  ?manager.activeInferenceModel,
  ?manager.activeEmbeddingModel,
  ?manager.activeSttModel,
  ?manager.activeTtsModel,
];

/// Refuses, before anything is downloaded, an install with an expectation
/// that would write over a file one of the [active] models reads (of any
/// kind): were the file then not what was expected, that model would be left
/// reading it. Without an expectation the install replaces it as before. Not
/// on the web, where nothing is checked.
///
/// The message names the model's kind, its name and the call that
/// uninstalls it, in the words [activeFileRefusal] writes: the example app
/// reads them, and a test holds them.
void refuseReplacingActive(
  List<FileInstallStep> steps,
  Map<String, FileExpectation> expected,
  List<ModelSpec> active,
) {
  if (kIsWeb) return;
  for (final step in steps) {
    if (!step.installs || (expected[step.file.filename]?.isEmpty ?? true)) {
      continue;
    }
    for (final model in active) {
      if (!model.files.any((f) => f.filename == step.file.filename)) continue;
      throw StateError(activeFileRefusal(step.file.filename, model));
    }
  }
}

/// What [refuseReplacingActive] says when an install would write [filename]
/// over a file the active [model] reads.
@visibleForTesting
String activeFileRefusal(String filename, ModelSpec model) {
  final kind = switch (model.type) {
    ModelManagementType.inference => 'inference',
    ModelManagementType.embedding => 'embedding',
    ModelManagementType.stt => 'speech-to-text',
    ModelManagementType.tts => 'text-to-speech',
  };
  final uninstall = _uninstallCall(filename, model);
  return 'This install would write $filename over the file the active $kind '
      'model ${model.name} reads, and checks it only afterwards. Uninstall '
      'that model first ($uninstall), or install under another file name.';
}

/// The call that uninstalls the active [model] reading [filename]: for an
/// inference model the file itself (its main file or its LoRA:
/// `uninstallModel` takes either record, and clears the active model that
/// reads it) or a directory model's name, quoted as a Dart string.
String _uninstallCall(String filename, ModelSpec model) => switch (model.type) {
  ModelManagementType.inference =>
    "FlutterEdgeAi.uninstallModel("
        "'${_dartQuoted(filename.contains('/') ? model.name : filename)}')",
  ModelManagementType.embedding => 'FlutterEdgeAi.uninstallEmbedder()',
  ModelManagementType.stt => 'FlutterEdgeAi.uninstallStt()',
  ModelManagementType.tts => 'FlutterEdgeAi.uninstallTts()',
};

String _dartQuoted(String text) =>
    text.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

/// Checks the files of [spec] against [expected] (by file name), before the
/// spec is made active: on every install, files installed earlier included,
/// so an install that stopped before its check proves nothing to the next
/// one. On the web, where the browser keeps the files, nothing is checked.
///
/// Throws [ModelValidationException] for a file of another size, or one core
/// has no copy of, after deleting the file and its record — the next install
/// downloads it again — unless one of the [active] models (of any kind, read
/// before the install) reads it: that file is left as it is.
Future<void> verifyInstalledFiles(
  ModelSpec spec,
  Map<String, FileExpectation> expected, {
  required List<ModelSpec> active,
}) async {
  if (kIsWeb || expected.values.every((e) => e.isEmpty)) return;
  final manager = FlutterEdgeAiPlugin.instance.modelManager;
  final registry = ServiceRegistry.instance;
  await checkInstalledFiles(
    spec,
    expected,
    paths: await manager.getModelFilePaths(spec),
    fileSystem: registry.fileSystemService,
    keep: {
      for (final model in active)
        for (final f in model.files) f.filename: model,
    },
    // The record first: a file the system will not let go of yet (Windows
    // keeps a file open by another process) is then an orphan the next
    // install writes over, never a record that skips its download.
    forget: (file, path) async {
      await registry.modelRepository.deleteModel(file.filename);
      if (path != null && await registry.fileSystemService.fileExists(path)) {
        await registry.fileSystemService.deleteFile(path);
      }
    },
  );
}

/// [verifyInstalledFiles] over given [paths] (core's paths by `prefsKey`,
/// null when core reports the spec not installed). [forget] deletes a file
/// with its record, unless [keep] names it (file name to the active model
/// that reads it).
@visibleForTesting
Future<void> checkInstalledFiles(
  ModelSpec spec,
  Map<String, FileExpectation> expected, {
  required Map<String, String>? paths,
  required FileSystemService fileSystem,
  required Future<void> Function(ModelFile file, String? path) forget,
  Map<String, ModelSpec> keep = const {},
}) async {
  final names = {for (final file in spec.files) file.filename};
  for (final MapEntry(key: name, value: expectation) in expected.entries) {
    if (!expectation.isEmpty && !names.contains(name)) {
      throw StateError('$name is expected, but ${spec.name} has no such file');
    }
  }

  /// Deletes [file] unless [keep] names it, and says what became of it and
  /// the way out. A delete that fails is named, never thrown in place of the
  /// check's error.
  Future<(String, Object?)> drop(ModelFile file, String? path) async {
    if (keep[file.filename] case final model?) {
      return (
        'The active model ${model.name} reads this file, so it was kept: '
            'uninstall it first (${_uninstallCall(file.filename, model)}), '
            'then install again.',
        null,
      );
    }
    try {
      await forget(file, path);
      return (
        'The file and its record were deleted; the next install downloads '
            'it again.',
        null,
      );
    } catch (e) {
      // The record goes first: when it is gone the next install downloads
      // over the file; when it is not, only an uninstall clears it.
      return (
        'Deleting it failed ($e). If isModelInstalled still lists '
            '${file.filename}, uninstall it before installing again; if not, '
            'the next install downloads over it.',
        e,
      );
    }
  }

  for (final file in spec.files) {
    final expectation = expected[file.filename];
    if (expectation == null || expectation.isEmpty) continue;
    final path = paths?[file.prefsKey];
    if (path == null || !await fileSystem.fileExists(path)) {
      final (what, failure) = await drop(file, path);
      throw ModelValidationException.mismatch(
        '${file.filename}: the install finished, but core has no file for it '
        'to check. $what',
        filePath: path,
        expectedSize: expectation.size,
        cause: failure,
      );
    }
    final size = await fileSystem.getFileSize(path);
    if (expectation.size case final want? when size != want) {
      final (what, failure) = await drop(file, path);
      throw ModelValidationException.mismatch(
        '${file.filename} is $size bytes, $want expected. $what',
        filePath: path,
        actualSize: size,
        expectedSize: want,
        cause: failure,
      );
    }
  }
}

/// A catalog variant that cannot be installed here is refused before
/// anything downloads: one its package runs on no backend in this runtime
/// (`backendsHere` empty), one with no file that is not a built-in model
/// (`ModelFileType.builtIn`, which the operating system provides), or one
/// whose files break the catalog's rules (a revision that
/// is not a commit, a size that is not positive, a sha256 that is not 64 hex
/// digits, an install name that is not a portable file name).
void checkCatalogVariant(CatalogVariant variant) {
  if (variant.backendsHere.isEmpty) {
    throw UnsupportedError(
      '${variant.id} does not run here: ${variant.catalogName} runs it on no '
      'backend in this runtime. Pick another variant, for example with '
      'CatalogModel.variantFor',
    );
  }
  final builtIn =
      variant is InferenceVariant && variant.fileType == ModelFileType.builtIn;
  if (variant.files.isEmpty && !builtIn) {
    throw UnsupportedError(
      '${variant.id} lists no file, and only a built-in model '
      '(ModelFileType.builtIn) installs without one',
    );
  }
  for (final file in variant.files) {
    final problem = switch (file) {
      _ when !_commit.hasMatch(file.revision) =>
        'revision ${file.revision} is not a 40-hex commit',
      _ when file.sizeBytes <= 0 => 'size ${file.sizeBytes} is not positive',
      _ when !_sha256Hex.hasMatch(file.sha256) =>
        'sha256 ${file.sha256} is not 64 hex digits',
      _ => null,
    };
    if (problem != null) {
      throw ArgumentError(
        '${variant.id}: ${file.path}: $problem (${variant.catalogName})',
      );
    }
    FileNameUtils.validatePortableFileNameSegment(file.installFilename);
  }
}
