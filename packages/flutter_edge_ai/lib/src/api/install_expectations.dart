import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show FlutterEdgeAiPlugin;
import 'package:flutter_edge_ai/src/api/file_sha256_io.dart'
    if (dart.library.js_interop) 'package:flutter_edge_ai/src/api/file_sha256_web.dart';
import 'package:flutter_edge_ai/src/catalog/model_catalog.dart';
import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/model.dart' show ModelFileType;
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/src/model_management/install_rule.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/services/file_system_service.dart';
import 'package:flutter_edge_ai/src/utils/file_name_utils.dart';
import 'package:meta/meta.dart' show visibleForTesting;

final _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');
final _commit = RegExp(r'^[0-9a-f]{40}$');

/// What an installed file should be: the `expectedSize` / `expectedSha256`
/// an installation builder was given for it. `const FileExpectation()` is
/// the empty one: nothing to check.
final class FileExpectation {
  /// An expectation; see [FileExpectation.checked] for one from a caller.
  const FileExpectation({this.size, this.sha256});

  /// [size] and [sha256] as a caller passed them, refused before anything
  /// downloads when they cannot be right: a negative size, a sha256 that is
  /// not 64 hex digits, or a sha256 on the web, which keeps no local file to
  /// hash ([UnsupportedError]).
  factory FileExpectation.checked({int? size, String? sha256}) {
    if (size != null && size < 0) {
      throw ArgumentError.value(size, 'expectedSize', 'must not be negative');
    }
    if (sha256 != null) {
      if (!_sha256Hex.hasMatch(sha256)) {
        throw ArgumentError.value(
          sha256,
          'expectedSha256',
          'must be 64 hex digits',
        );
      }
      if (kIsWeb) {
        throw UnsupportedError(
          'expectedSha256 is not checked on the web: the browser keeps the '
          'file, and there is no local file to hash',
        );
      }
    }
    return FileExpectation(size: size, sha256: sha256?.toLowerCase());
  }

  /// Bytes, exactly.
  final int? size;

  /// Lower-case hex.
  final String? sha256;

  /// Whether there is anything to check.
  bool get isEmpty => size == null && sha256 == null;
}

/// The largest file the web's default storage, the Cache API, holds: a file
/// is read whole into one `ArrayBuffer`, which browsers cap near 2 GiB.
const webCacheLimitBytes = 2 * 1024 * 1024 * 1024;

/// Refuses, before anything is downloaded, a file whose expected size is over
/// [webCacheLimitBytes] on the web in the default `WebStorageMode.cacheApi`:
/// the download would fail part-way. `WebStorageMode.streaming` (OPFS) holds
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
    '${tooLarge.join(', ')} is over 2 GB, more than the web\'s default '
    'storage (WebStorageMode.cacheApi) holds. Pass '
    'webStorageMode: WebStorageMode.streaming to FlutterEdgeAi.initialize.',
  );
}

/// Refuses, before anything is downloaded, an install with an expectation
/// that would write over a file the [active] model of the same kind reads:
/// were the file then not what was expected, the active model would be left
/// reading it. Without an expectation the install replaces it as before.
void refuseReplacingActive(
  List<FileInstallStep> steps,
  Map<String, FileExpectation> expected,
  ModelSpec? active,
) {
  if (kIsWeb || active == null) return;
  final activeNames = {for (final f in active.files) f.filename};
  final replaced = [
    for (final step in steps)
      if (step.installs &&
          activeNames.contains(step.file.filename) &&
          !(expected[step.file.filename]?.isEmpty ?? true))
        step.file.filename,
  ];
  if (replaced.isEmpty) return;
  throw StateError(
    'This install would write ${replaced.join(', ')} over the file the active '
    'model ${active.name} reads, and checks it only afterwards. Uninstall '
    '${active.name} first, or install under another file name.',
  );
}

/// Checks the files of [spec] against [expected] (by file name), before the
/// spec is made active: on every install, files installed earlier included,
/// so an install that stopped before its check proves nothing to the next
/// one. On the web, where the browser keeps the files, nothing is checked.
///
/// Throws [ModelValidationException] for a file of another size or sha256,
/// or one core has no copy of, after deleting the file and its record — the
/// next install downloads it again — unless the [active] model of the same
/// kind (read before the install) reads it: that file is left as it is. A
/// check that ends without proving its files (a cancel through
/// [cancelToken], a file that cannot be read) deletes what [steps] wrote
/// and throws what stopped it.
Future<void> verifyInstalledFiles(
  ModelSpec spec,
  Map<String, FileExpectation> expected, {
  required List<FileInstallStep> steps,
  required ModelSpec? active,
  CancelToken? cancelToken,
}) async {
  if (kIsWeb || expected.values.every((e) => e.isEmpty)) return;
  final manager = FlutterEdgeAiPlugin.instance.modelManager;
  final registry = ServiceRegistry.instance;
  await checkInstalledFiles(
    spec,
    expected,
    paths: await manager.getModelFilePaths(spec),
    fileSystem: registry.fileSystemService,
    written: {
      for (final step in steps)
        if (step.installs) step.file.filename,
    },
    keep: {...?active?.files.map((f) => f.filename)},
    // The record first: a file the system will not let go of yet (Windows
    // keeps a file open by another process) is then an orphan the next
    // install writes over, never a record that skips its download.
    forget: (file, path) async {
      await registry.modelRepository.deleteModel(file.filename);
      if (path != null && await registry.fileSystemService.fileExists(path)) {
        await registry.fileSystemService.deleteFile(path);
      }
    },
    sha256Of: (path) => fileSha256(path, cancelToken: cancelToken),
  );
}

/// [verifyInstalledFiles] over given [paths] (core's paths by `prefsKey`,
/// null when core reports the spec not installed). [forget] deletes a file
/// with its record, unless [keep] names it; [written] are the files this
/// install wrote, deleted when the check ends without a verdict.
@visibleForTesting
Future<void> checkInstalledFiles(
  ModelSpec spec,
  Map<String, FileExpectation> expected, {
  required Map<String, String>? paths,
  required FileSystemService fileSystem,
  required Set<String> written,
  required Future<void> Function(ModelFile file, String? path) forget,
  required Future<String> Function(String path) sha256Of,
  Set<String> keep = const {},
}) async {
  final names = {for (final file in spec.files) file.filename};
  for (final MapEntry(key: name, value: expectation) in expected.entries) {
    if (!expectation.isEmpty && !names.contains(name)) {
      throw StateError('$name is expected, but ${spec.name} has no such file');
    }
  }

  /// Deletes [file] unless [keep] names it, and says what became of it. A
  /// delete that fails is named, never thrown in place of the check's error.
  Future<(String, Object?)> drop(ModelFile file, String? path) async {
    if (keep.contains(file.filename)) {
      return (
        'The active model reads this file, so it was left as it is.',
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
      return (
        'Deleting it failed ($e); uninstall it before installing it '
            'again.',
        e,
      );
    }
  }

  try {
    for (final file in spec.files) {
      final expectation = expected[file.filename];
      if (expectation == null || expectation.isEmpty) continue;
      final path = paths?[file.prefsKey];
      if (path == null || !await fileSystem.fileExists(path)) {
        final (what, failure) = await drop(file, path);
        throw ModelValidationException.mismatch(
          '${file.filename}: the install finished, but core has no file for '
          'it to check. $what',
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
      if (expectation.sha256 case final want?) {
        final got = await sha256Of(path);
        if (got != want) {
          final (what, failure) = await drop(file, path);
          throw ModelValidationException.mismatch(
            '${file.filename} has sha256 $got, $want expected. $what',
            filePath: path,
            actualSize: size,
            cause: failure,
          );
        }
      }
    }
  } on ModelValidationException {
    rethrow;
  } catch (e, stack) {
    // The check ended without a verdict: what this install wrote is not
    // proven, so it does not stay for the next install to find.
    for (final file in spec.files) {
      if (!written.contains(file.filename) || keep.contains(file.filename)) {
        continue;
      }
      try {
        await forget(file, paths?[file.prefsKey]);
      } catch (_) {
        // The check's own error is what the caller needs; this file is
        // checked again (and hashed) by the next install.
      }
    }
    Error.throwWithStackTrace(e, stack);
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
