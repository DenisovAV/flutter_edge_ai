/// The tool-call syntax FunctionGemma and Gemma 4 share:
/// `START call:NAME{key:value,...}`, with string values between an escape
/// token — `<escape>` for FunctionGemma, `<|"|>` for Gemma 4.
///
/// Both models write it with the `format_argument` macro of their own
/// `chat_template.jinja` (called with `escape_keys=False` for call arguments):
///
///   string  -> ESCAPE text ESCAPE
///   boolean -> bare `true` / `false`
///   null    -> bare `None` (FunctionGemma: Python's `str`) or `null` (Gemma 4)
///   number  -> bare `42`, `-3`, `1.5`, `-0.25`
///   list    -> `[item,item]`   (items recurse)
///   object  -> `{key:value}`   (bare keys, items recurse)
///
/// A regex cannot read it: an escaped string may itself contain `,`, `}` or
/// `]`, and objects nest. So the argument list is walked once with a cursor.
/// Anything that cannot be classified is kept verbatim as a String rather than
/// silently dropped.
library;

/// A call found by [findEscapedCall]: its [name], the text between its outer
/// braces ([body]), and the index just past its closing brace ([end]).
typedef EscapedCall = ({String name, String body, int end});

/// Locates the first `START call:NAME{...}` at or after [from] and returns the
/// name plus its balanced body, or `null` when there is none or the call is
/// still arriving.
///
/// `}` is not a terminator: it closes a nested object, or sits inside an
/// escaped string value. So escape spans are opaque here and brace depth — not
/// the first `}` — ends the call. A closing tag after the body is not needed;
/// a stop token often eats it.
EscapedCall? findEscapedCall(
  String text, {
  required String start,
  required String escape,
  int from = 0,
}) {
  const callPrefix = 'call:';

  final startIndex = text.indexOf(start, from);
  if (startIndex == -1) return null;

  var i = startIndex + start.length;
  if (!text.startsWith(callPrefix, i)) return null;
  i += callPrefix.length;

  final name = _readKey(text, i);
  if (name == null) return null;
  i = name.$2;

  if (i >= text.length || text[i] != '{') return null;
  final open = i;
  var depth = 0;

  while (i < text.length) {
    if (text.startsWith(escape, i)) {
      final close = text.indexOf(escape, i + escape.length);
      if (close == -1) return null; // string value still streaming
      i = close + escape.length;
      continue;
    }

    final char = text[i];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return (name: name.$1, body: text.substring(open + 1, i), end: i + 1);
      }
    }
    i++;
  }

  return null;
}

/// Parses the `{...}` body of a call into typed arguments, or returns `null`
/// when the body does not parse in full.
///
/// The templates do not escape the escape token inside a string value, so a
/// value containing it is genuinely ambiguous on the wire. Keeping the
/// arguments read so far would fire the tool with a truncated string and
/// silently drop everything after it. Refuse the whole call instead — the chat
/// then surfaces the raw text, and the failure is visible.
Map<String, dynamic>? parseEscapedCallArguments(
  String body, {
  required String escape,
}) {
  final params = <String, dynamic>{};
  var i = 0;
  while (true) {
    i = _skipWhitespace(body, i);
    if (i >= body.length) return params;

    final key = _readKey(body, i);
    if (key == null) return null;
    i = _skipWhitespace(body, key.$2);
    if (i >= body.length || body[i] != ':') return null;

    final parsed = _parseValue(body, i + 1, escape);
    if (parsed == null) return null;
    params[key.$1] = parsed.$1;

    i = _skipWhitespace(body, parsed.$2);
    if (i >= body.length) return params;
    if (body[i] != ',') return null;
    i++;
  }
}

/// `\w` plus `-`: tool and argument names such as `get-current-time`.
bool _isNameChar(int c) =>
    (c >= 0x30 && c <= 0x39) || // 0-9
    (c >= 0x41 && c <= 0x5A) || // A-Z
    (c >= 0x61 && c <= 0x7A) || // a-z
    c == 0x5F || // _
    c == 0x2D; // -

bool _isValueEnd(String c) => c == ',' || c == ']' || c == '}';

int _skipWhitespace(String src, int i) {
  while (i < src.length && src[i].trim().isEmpty) {
    i++;
  }
  return i;
}

/// Reads a name starting at [i]. Returns `null` when there is none.
(String, int)? _readKey(String src, int i) {
  final start = i;
  while (i < src.length && _isNameChar(src.codeUnitAt(i))) {
    i++;
  }
  if (i == start) return null;
  return (src.substring(start, i), i);
}

/// The only numeric shapes Python's `str()` — and so the templates — can
/// render. Dart's `int.tryParse`/`double.tryParse` also accept `0x1f`, `+5`,
/// `007`, `Infinity` and `NaN`; reading those as numbers invents a type the
/// model never meant.
final _bareNumber = RegExp(r'^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][-+]?\d+)?$');

/// Classifies a bare (unescaped) token exactly as the templates' non-string
/// branches would have rendered it. Unrecognised tokens survive as Strings.
dynamic _classifyBareToken(String token) {
  if (token == 'true') return true;
  if (token == 'false') return false;
  // FunctionGemma writes Python's `None`, Gemma 4 writes `null`. A real "None"
  // or "null" string arrives escape-wrapped, so nothing collides.
  if (token == 'None' || token == 'null') return null;
  if (!_bareNumber.hasMatch(token)) return token;
  return int.tryParse(token) ?? double.tryParse(token) ?? token;
}

/// Parses one value starting at [i]; returns the value and the next index, or
/// `null` when the value is malformed.
(dynamic, int)? _parseValue(String src, int i, String escape) {
  i = _skipWhitespace(src, i);
  if (i >= src.length) return ('', i);

  // Escaped string: consumes up to its own closing marker, so embedded
  // commas/brackets are preserved.
  if (src.startsWith(escape, i)) {
    final start = i + escape.length;
    final end = src.indexOf(escape, start);
    if (end == -1) return null; // the string never closes
    return (src.substring(start, end), end + escape.length);
  }

  if (src[i] == '[') {
    final list = <dynamic>[];
    i = _skipWhitespace(src, i + 1);
    if (i < src.length && src[i] == ']') return (list, i + 1);
    while (true) {
      final parsed = _parseValue(src, i, escape);
      if (parsed == null) return null;
      list.add(parsed.$1);
      i = _skipWhitespace(src, parsed.$2);
      if (i >= src.length) return null;
      if (src[i] == ',') {
        i++;
        continue;
      }
      if (src[i] == ']') return (list, i + 1);
      return null;
    }
  }

  if (src[i] == '{') {
    final map = <String, dynamic>{};
    i = _skipWhitespace(src, i + 1);
    if (i < src.length && src[i] == '}') return (map, i + 1);
    while (true) {
      i = _skipWhitespace(src, i);
      final key = _readKey(src, i);
      if (key == null) return null;
      i = _skipWhitespace(src, key.$2);
      if (i >= src.length || src[i] != ':') return null;
      final parsed = _parseValue(src, i + 1, escape);
      if (parsed == null) return null;
      map[key.$1] = parsed.$1;
      i = _skipWhitespace(src, parsed.$2);
      if (i >= src.length) return null;
      if (src[i] == ',') {
        i++;
        continue;
      }
      if (src[i] == '}') return (map, i + 1);
      return null;
    }
  }

  final start = i;
  while (i < src.length && !_isValueEnd(src[i])) {
    i++;
  }
  return (_classifyBareToken(src.substring(start, i).trim()), i);
}
