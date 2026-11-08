/// Native arm of the local-model lookup: `dart:io` lives here rather than in
/// the test, because a test that also runs on web under `flutter drive` cannot
/// import it at all — the web compilers reject `dart:io` before any `kIsWeb`
/// guard runs.
library;

import 'dart:io' as io;

const _macosContainerData =
    '/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data';

/// Path to [fileName] in the macOS staging directory.
///
/// Unsandboxed test apps prefer `~/models`, which avoids macOS TCC denying
/// access to the example app's container. Sandboxed builds cannot read that
/// directory and keep using their container Documents directory.
String? macosStagedFilePath(String fileName) {
  if (!io.Platform.isMacOS) return null;
  final home = io.Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;

  final models = '$home/models/$fileName';
  if (io.FileSystemEntity.typeSync(models) !=
      io.FileSystemEntityType.notFound) {
    return models;
  }

  return home.endsWith(_macosContainerData)
      ? '$home/Documents/$fileName'
      : '$home$_macosContainerData/Documents/$fileName';
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
