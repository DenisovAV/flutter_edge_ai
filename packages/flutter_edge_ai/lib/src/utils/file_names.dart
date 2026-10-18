// File-name predicates engine packages share with core, as top-level functions
// over the internal [FileNameUtils] (which stays unexported). Exported by
// `package:flutter_edge_ai/engine.dart`. Pure Dart; web-safe.

import 'file_name_utils.dart';

const String _liteRtLmSuffix = '.litertlm';

/// Whether [filename] ends in `.litertlm`, compared ASCII case-insensitively
/// (`model.LiteRTLM` matches; only `A`–`Z` fold, so a non-ASCII look-alike
/// never does).
///
/// The one predicate core and engine packages use to tell a `.litertlm`
/// bundle from any other model file.
bool isLiteRtLmFilename(String filename) {
  final start = filename.length - _liteRtLmSuffix.length;
  if (start < 0) return false;
  for (var i = 0; i < _liteRtLmSuffix.length; i++) {
    var c = filename.codeUnitAt(start + i);
    // ASCII 'A'..'Z' → 'a'..'z'; every other code unit compares as is.
    if (c >= 0x41 && c <= 0x5A) c += 0x20;
    if (c != _liteRtLmSuffix.codeUnitAt(i)) return false;
  }
  return true;
}

/// Internal install predicate: these containers include their own tokenizer.
/// The resolved install filename decides, including an explicit filename for
/// an opaque URL. This does not select an embedding backend.
bool isSelfContainedEmbeddingFilename(String filename) =>
    isLiteRtLmFilename(filename) || filename.toLowerCase().endsWith('.gguf');

/// A filesystem-safe, single-segment directory name for a directory model
/// (ORT-GenAI) installed from the Hugging Face repo [repo], optionally from its
/// execution-provider subfolder [variant].
///
/// Throws [ArgumentError] when the result would be empty or dot-only. Same
/// contract as the resolver-facing helper it wraps.
String sanitizeHfDirName(String repo, {String? variant}) =>
    FileNameUtils.sanitizeHfDirName(repo, variant: variant);
