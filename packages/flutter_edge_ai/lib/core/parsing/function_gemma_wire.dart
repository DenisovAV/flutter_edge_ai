/// FunctionGemma's wire format, in one place.
///
/// Both halves of the protocol live here: the tokens, and the `format_argument`
/// macro of the model's own `chat_template.jinja`. Declarations (`chat.dart`)
/// and tool responses (`extensions.dart`) both render through it, so the two
/// cannot drift apart the way the encoder and decoder once did.
library;

// FunctionGemma special tokens
const functionGemmaStartCall = '<start_function_call>';
const functionGemmaEndCall = '<end_function_call>';
const functionGemmaStartDecl = '<start_function_declaration>';
const functionGemmaEndDecl = '<end_function_declaration>';
const functionGemmaStartResp = '<start_function_response>';
const functionGemmaEndResp = '<end_function_response>';
const functionGemmaEscape = '<escape>';

/// Python's `str.lower()`, which Jinja's `dictsort` folds keys with. Dart maps
/// `İ` (U+0130) to a plain `i`; Python appends a combining dot, which sorts
/// after it.
String functionGemmaFold(String key) => key.replaceAll('İ', 'i̇').toLowerCase();

/// Jinja's `dictsort`, which defaults to `case_sensitive=False`. A plain
/// `.sort()` would put `Beta` before `alpha`; the template does the reverse.
///
/// Jinja's sort is stable, Dart's `List.sort` is not (it drops to an unstable
/// quicksort past 32 elements), so ties like `Foo`/`foo` are broken by
/// insertion order explicitly.
List<String> functionGemmaDictsort(Iterable<String> keys) {
  final indexed = keys.toList().indexed.toList();
  indexed.sort((a, b) {
    final byKey = functionGemmaFold(a.$2).compareTo(functionGemmaFold(b.$2));
    return byKey != 0 ? byKey : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

/// Python's `str(float)`. The template is Jinja, so every number in the prompt
/// was formatted by Python. Both languages print the shortest round-trip
/// digits, but they switch to exponent notation at different magnitudes:
/// Python below `1e-4` and from `1e16`, Dart below `1e-6` and from `1e21`.
String functionGemmaDouble(double value) {
  if (value.isNaN) return 'nan';
  if (value.isInfinite) return value.isNegative ? '-inf' : 'inf';

  final magnitude = value.abs();
  if (magnitude == 0 || (magnitude >= 1e-4 && magnitude < 1e16)) {
    return value.toString();
  }

  // Dart writes `1e-5`, Python pads the exponent to two digits: `1e-05`.
  final exponential = value.toStringAsExponential();
  final parts = RegExp(r'^(.*)e([+-])(\d+)$').firstMatch(exponential);
  if (parts == null) return exponential;
  return '${parts.group(1)}e${parts.group(2)}${parts.group(3)!.padLeft(2, '0')}';
}

/// Jinja renders a bare `{{ value }}` through Python's `str()`, so booleans
/// capitalise, `null` becomes `None`, and floats follow Python's notation.
String functionGemmaScalar(dynamic value) {
  if (value is bool) return value ? 'True' : 'False';
  if (value is double) return functionGemmaDouble(value);
  if (value == null) return 'None';
  return '$value';
}

/// The template's `format_argument` macro: strings are escape-wrapped,
/// booleans and numbers stay bare, lists and maps recurse.
String functionGemmaArgument(dynamic value, {bool escapeKeys = true}) {
  if (value is String) {
    return '$functionGemmaEscape$value$functionGemmaEscape';
  }
  if (value is bool) return value ? 'true' : 'false';
  if (value is List) {
    final items = value.map(
      (v) => functionGemmaArgument(v, escapeKeys: escapeKeys),
    );
    return '[${items.join(',')}]';
  }
  if (value is Map) {
    final entries = functionGemmaDictsort(value.keys.map((k) => '$k')).map((
      key,
    ) {
      final renderedKey = escapeKeys
          ? '$functionGemmaEscape$key$functionGemmaEscape'
          : key;
      final rendered = functionGemmaArgument(
        value[key],
        escapeKeys: escapeKeys,
      );
      return '$renderedKey:$rendered';
    });
    return '{${entries.join(',')}}';
  }
  // Numbers and `None` fall through the macro's `{{ value }}` branch.
  return functionGemmaScalar(value);
}

/// The body of `response:NAME{...}`.
///
/// The template splays a map response into its own dictsorted `key:value`
/// pairs — bare keys, values through `format_argument` — and falls back to a
/// single `value:` key for a scalar. It never wraps the result in a JSON blob.
String functionGemmaResponseBody(Object? response) {
  if (response is Map) {
    final entries = functionGemmaDictsort(response.keys.map((k) => '$k')).map(
      (key) =>
          '$key:${functionGemmaArgument(response[key], escapeKeys: false)}',
    );
    return entries.join(',');
  }
  return 'value:${functionGemmaArgument(response, escapeKeys: false)}';
}
