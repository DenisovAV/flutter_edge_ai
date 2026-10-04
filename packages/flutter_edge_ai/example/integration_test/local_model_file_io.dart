/// Native arm of the local-model lookup: `dart:io` lives here rather than in
/// the test, because a test that also runs on web under `flutter drive` cannot
/// import it at all — the web compilers reject `dart:io` before any `kIsWeb`
/// guard runs.
library;

import 'dart:io' as io;

/// Path to [fileName] in the directory this platform's device tests push models
/// to, when the file is really there — otherwise null, and the caller installs
/// from the network instead.
String? localModelFile(String fileName) {
  if (io.Platform.isAndroid) {
    return _existing('/data/local/tmp/flutter_gemma_test/$fileName');
  }
  if (io.Platform.isMacOS) {
    final home = io.Platform.environment['HOME'];
    if (home == null) return null;
    // The example app is sandboxed, so its HOME is already the container's
    // Data folder; an unsandboxed build still sees the real home.
    return _existing('$home/Documents/$fileName') ??
        _existing(
          '$home/Library/Containers/dev.flutterberlin.flutterGemmaExample55/'
          'Data/Documents/$fileName',
        );
  }
  // iOS and the desktops other than macOS have no agreed push location; those
  // runs download the model.
  return null;
}

String? _existing(String path) => io.File(path).existsSync() ? path : null;
