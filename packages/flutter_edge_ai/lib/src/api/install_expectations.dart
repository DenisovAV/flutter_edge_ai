import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show FlutterEdgeAiPlugin;
import 'package:flutter_edge_ai/src/api/file_sha256_io.dart'
    if (dart.library.js_interop) 'package:flutter_edge_ai/src/api/file_sha256_web.dart';
import 'package:flutter_edge_ai/src/catalog/model_catalog.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/services/file_system_service.dart';
import 'package:meta/meta.dart' show visibleForTesting;

/// What an installed file should be: the `expectedSize` / `expectedSha256`
/// an installation builder was given for it.
final class FileExpectation {
  /// An expectation; at least one of the two is set.
  const FileExpectation({this.size, this.sha256});

  /// Bytes, exactly.
  final int? size;

  /// Lower-case hex.
  final String? sha256;

  /// Whether there is anything to check.
  bool get isEmpty => size == null && sha256 == null;
}

/// Checks the files of [spec] the install just wrote against [expected] (by
/// file name), before the spec is made active. On the web, where the browser
/// keeps the files, nothing is checked.
///
/// Throws [ModelValidationException] for a file of another size or sha256:
/// it stays installed and the spec is not made active. [active] is the model
/// of the same kind active before this install; when the file shares its
/// name, the message says that the active model's file was replaced.
Future<void> verifyInstalledFiles(
  ModelSpec spec,
  Map<String, FileExpectation> expected, {
  ModelSpec? active,
}) async {
  if (kIsWeb || expected.values.every((e) => e.isEmpty)) return;
  final manager = FlutterEdgeAiPlugin.instance.modelManager;
  await checkInstalledFiles(
    spec,
    expected,
    paths: await manager.getModelFilePaths(spec),
    fileSystem: ServiceRegistry.instance.fileSystemService,
    active: active,
  );
}

/// [verifyInstalledFiles] over given [paths] (core's paths by `prefsKey`,
/// null when core reports the spec not installed).
@visibleForTesting
Future<void> checkInstalledFiles(
  ModelSpec spec,
  Map<String, FileExpectation> expected, {
  required Map<String, String>? paths,
  required FileSystemService fileSystem,
  ModelSpec? active,
  Future<String> Function(String path) sha256Of = fileSha256,
}) async {
  for (final file in spec.files) {
    final expectation = expected[file.filename];
    if (expectation == null || expectation.isEmpty) continue;
    final path = paths?[file.prefsKey];
    if (path == null || !await fileSystem.fileExists(path)) {
      throw ModelValidationException.mismatch(
        '${file.filename}: the install finished, but core has no file for '
        'it to check',
        filePath: path,
        expectedSize: expectation.size,
      );
    }
    final replaced =
        active != null && active.files.any((f) => f.filename == file.filename);
    final consequence = replaced
        ? 'It replaced the file of the active model ${active.name}, which now '
              'reads it; uninstall it and install again.'
        : 'The file stays installed but was not made active; uninstall it and '
              'install again.';
    final size = await fileSystem.getFileSize(path);
    if (expectation.size case final want? when size != want) {
      throw ModelValidationException.mismatch(
        '${file.filename} is $size bytes, $want expected. $consequence',
        filePath: path,
        actualSize: size,
        expectedSize: want,
      );
    }
    if (expectation.sha256 case final want?) {
      final got = await sha256Of(path);
      if (got != want.toLowerCase()) {
        throw ModelValidationException.mismatch(
          '${file.filename} has sha256 $got, $want expected. $consequence',
          filePath: path,
          actualSize: size,
        );
      }
    }
  }
}

/// A catalog variant that cannot be installed here is refused before
/// anything downloads: one its package runs on no backend in this runtime
/// (`backendsHere` empty), or one with no file (a model the operating system
/// provides).
void checkCatalogVariant(CatalogVariant variant) {
  if (variant.backendsHere.isEmpty) {
    throw UnsupportedError(
      '${variant.id} does not run here: ${variant.catalogName} runs it on no '
      'backend in this runtime. Pick another variant, for example with '
      'CatalogModel.variantFor',
    );
  }
  if (variant.files.isEmpty) {
    throw UnsupportedError(
      '${variant.id} is provided by the operating system; there is nothing to '
      'install',
    );
  }
}
