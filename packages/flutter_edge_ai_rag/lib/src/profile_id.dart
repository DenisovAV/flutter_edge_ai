/// The id rules of `EmbeddingProfile`, shared by every place that accepts an
/// id or a piece of one. Not exported.
///
/// U+0000–U+001F are refused: U+001F qualifies the stored id of an image or
/// audio binding (`'<id>\u001F<modality>'`), so a real id can never equal a
/// qualified one, and the other control characters have no business in an
/// identity that is printed in error messages and written to disk.
void checkProfileIdText(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  for (final unit in value.codeUnits) {
    if (unit <= 0x1F) {
      throw ArgumentError.value(
        printableId(value),
        name,
        'must not contain control characters (U+0000–U+001F); found '
        'U+${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}',
      );
    }
  }
}

/// [value] with every control character written as a `\uXXXX` escape, for
/// messages about ids read from storage (a qualified id contains U+001F).
String printableId(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    if (rune <= 0x1F) {
      out.write('\\u${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}
