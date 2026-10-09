/// Parses a number the way a model or a person writes one: `18500`,
/// `"$18,500"`, `"18 500"`, `"6%"`, `"0.06"`.
///
/// Returns null for null, for non-numeric strings and for any other type, so
/// callers decide whether a missing value is an error. Currency symbols,
/// thousands separators and spaces are stripped; a trailing `%` divides by
/// 100 so that `"6%"` and `0.06` mean the same rate. The `k` suffix is not
/// handled here: it belongs to free text, where the narration guard reads it.
double? parseTolerantNumber(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is! String) return null;
  var cleaned = value.replaceAll(RegExp(r'[\$,\s]'), '');
  final percent = cleaned.endsWith('%');
  if (percent) cleaned = cleaned.substring(0, cleaned.length - 1);
  final parsed = double.tryParse(cleaned);
  if (parsed == null) return null;
  return percent ? parsed / 100 : parsed;
}
