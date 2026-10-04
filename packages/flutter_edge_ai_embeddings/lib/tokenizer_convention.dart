/// Public export of the `tokenizer.json` convention reader, for engine packages
/// that route a tokenizer file to an adapter and need to know which convention
/// the file declares before building anything.
///
/// Unlike `embedding_tokenizer.dart` and `wordpiece_embedding_tokenizer.dart` at
/// this package's root, this one is **web-safe**: it is pure Dart over an
/// already-decoded map, with no `dart:io` and no tokenizer dependency, so an
/// engine's web arm can use the same routing rule as its native arm.
library;

export 'src/tokenizer_convention.dart' show isSiglip2TokenizerJson;
