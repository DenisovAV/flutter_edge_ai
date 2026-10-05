/// Native arm of the [readTextFile] seam.
///
/// `dart:io` lives HERE and nowhere near `wordpiece_embedding_tokenizer.dart`.
/// That file is imported directly by `flutter_gemma_onnx`'s **web** embedding
/// arm, and an unconditional `import 'dart:io'` makes a whole library
/// uncompilable for web — which is why
/// `WordPieceEmbeddingTokenizer.fromPath` was deleted outright in #449 rather
/// than moved. Deleting it removed a method that had already shipped in
/// published 2.0.0, so it came back through this seam instead: the public API
/// is unchanged, and the web arm still compiles because it resolves the stub.
///
/// Same `if (dart.library.…)` technique that PR's own barrel split used to keep
/// `dart:ffi`/`dart:io` out of the web bundle.
library;

import 'dart:io';

Future<String> readTextFile(String path) => File(path).readAsString();
