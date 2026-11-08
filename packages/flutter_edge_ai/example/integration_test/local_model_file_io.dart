/// Native arm of the local-model lookup: `dart:io` lives here rather than in
/// the test, because a test that also runs on web under `flutter drive` cannot
/// import it at all — the web compilers reject `dart:io` before any `kIsWeb`
/// guard runs.
library;

import 'dart:io' as io;

const _macosContainerData =
    '/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data';

/// The example app's container Documents path for [fileName].
///
/// This remains available to tests that preserve their old off-macOS skip
/// path, but macOS callers should use [macosStagedFilePath].
String macosContainerDocumentsPath(String fileName) {
  return '${_macosContainerDocumentsRoot()}/$fileName';
}

String _macosContainerDocumentsRoot() {
  final home = io.Platform.environment['HOME'];
  return home != null && home.endsWith(_macosContainerData)
      ? '$home/Documents'
      : '$home$_macosContainerData/Documents';
}

/// Root containing the complete macOS staging set in [requiredFiles].
///
/// A partial `~/models` set is ignored so one runtime never mixes mutually
/// dependent artifacts with files from the container Documents fallback.
String? macosStagedRoot(Iterable<String> requiredFiles) {
  if (!io.Platform.isMacOS) return null;
  final home = io.Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;

  final modelsRoot = '$home/models';
  final complete = requiredFiles.every(
    (fileName) =>
        io.FileSystemEntity.typeSync('$modelsRoot/$fileName') !=
        io.FileSystemEntityType.notFound,
  );
  return complete ? modelsRoot : _macosContainerDocumentsRoot();
}

/// Path to [fileName] in the macOS staging directory.
///
/// Unsandboxed test apps prefer `~/models`, which avoids macOS TCC denying
/// access to the example app's container. Sandboxed builds cannot read that
/// directory and keep using their container Documents directory.
String? macosStagedFilePath(String fileName) {
  final root = macosStagedRoot([fileName]);
  return root == null ? null : '$root/$fileName';
}

/// Path to [fileName] in the directory this platform's device tests push models
/// to, when the file is really there — otherwise null, and the caller installs
/// from the network instead.
String? localModelFile(String fileName) {
  if (io.Platform.isAndroid) {
    return _existing('/data/local/tmp/flutter_gemma_test/$fileName');
  }
  if (io.Platform.isMacOS) {
    final path = macosStagedFilePath(fileName);
    return path == null ? null : _existing(path);
  }
  // iOS and the desktops other than macOS have no agreed push location; those
  // runs download the model.
  return null;
}

String? _existing(String path) => io.File(path).existsSync() ? path : null;
