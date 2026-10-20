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
bool isLiteRtLmFilename(String filename) =>
    _hasAsciiSuffix(filename, _liteRtLmSuffix);

/// Internal install predicate: these containers include their own tokenizer.
/// The resolved install filename decides, including an explicit filename for
/// an opaque URL. This does not select an embedding backend.
bool isSelfContainedEmbeddingFilename(String filename) =>
    isLiteRtLmFilename(filename) || _hasAsciiSuffix(filename, '.gguf');

bool _hasAsciiSuffix(String filename, String suffix) {
  final start = filename.length - suffix.length;
  if (start < 0) return false;
  for (var i = 0; i < suffix.length; i++) {
    var c = filename.codeUnitAt(start + i);
    if (c >= 0x41 && c <= 0x5A) c += 0x20;
    if (c != suffix.codeUnitAt(i)) return false;
  }
  return true;
}

/// A filesystem-safe, single-segment directory name for a directory model
/// (ORT-GenAI) installed from the Hugging Face repo [repo], optionally from its
/// execution-provider subfolder [variant].
///
/// Throws [ArgumentError] when the result would be empty or dot-only. Same
/// contract as the resolver-facing helper it wraps.
String sanitizeHfDirName(String repo, {String? variant}) =>
    FileNameUtils.sanitizeHfDirName(repo, variant: variant);
