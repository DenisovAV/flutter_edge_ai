import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// The profile id `FlutterEdgeAiActiveEmbedder.forActiveModel` derives:
/// `'<namespace>@<installed file names joined by +>'`, in the spec's file
/// order (model first, then its tokenizer when it has one). Not exported; a
/// function of its own so the derivation is tested without an installed
/// model.
///
/// Injective: the namespace and every file name are percent-encoded for the
/// characters that would let two different (namespace, files) pairs spell
/// the same id — `%` and the delimiters `@` and `+` — and for U+0000–U+001F,
/// which a profile id may not contain. Names without those characters are
/// unchanged, so their ids read exactly `'<namespace>@<a>+<b>'`.
String activeModelProfileId({
  required String namespace,
  required EmbeddingModelSpec spec,
}) =>
    '${_escape(namespace)}@'
    '${[for (final file in spec.files) _escape(file.filename)].join('+')}';

String _escape(String part) {
  final out = StringBuffer();
  for (final unit in part.codeUnits) {
    if (unit <= 0x1F || unit == 0x25 || unit == 0x2B || unit == 0x40) {
      out.write('%${unit.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}
