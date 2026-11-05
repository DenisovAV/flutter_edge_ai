import 'dart:convert';

/// What every reply of a session must be: fixed for the session's lifetime.
///
/// Pass one as `responseFormat` to `InferenceModel.openSession` or
/// `InferenceModel.openChat`. Every reply of that session is then checked
/// by core: a reply that is not complete fails with
/// `IncompleteStructuredOutputException`, one that is not a value of the
/// format with `NonConformingStructuredOutputException`. A model that cannot
/// enforce the format refuses it when the session is opened
/// (`ResponseFormatUnsupportedException`); `InferenceModel.refusalFor` says
/// so beforehand.
///
/// Not sealed, and not subclassable outside core: a later kind (a regex) is
/// added without breaking an app's `switch`.
abstract final class ResponseFormat {
  const ResponseFormat._();

  /// A JSON value valid against [schema], in [ResponseFormat.dialect]. The
  /// schema is deep-copied into unmodifiable maps and lists.
  ///
  /// Throws [ArgumentError] when [schema] is not JSON-encodable, its root is
  /// not a map, or it is not well formed in the dialect. A keyword outside
  /// the dialect is not an ArgumentError: the model refuses it, with its
  /// path, when a session is opened.
  ///
  /// Well formed means: `type` is one of `object`, `array`, `string`,
  /// `integer`, `number`, `boolean`, `null`, as a single string, and the root
  /// declares one; every subschema is a map; `properties` is a map of
  /// subschemas; `required` a list of unique names, each in `properties`;
  /// `additionalProperties` only `false`; `items` one subschema; `minItems ≤
  /// maxItems` and `minLength ≤ maxLength`, non-negative integers (lengths
  /// count Unicode code points); `minimum ≤ maximum`, numbers; `enum` a
  /// non-empty list of unique JSON values; `const` one JSON value; nesting no
  /// deeper than 32 levels. `integer` accepts a JSON number with no
  /// fractional part (`1.0` is an integer).
  factory ResponseFormat.jsonSchema(
    Map<String, Object?> schema, {
    String? name,
  }) = JsonSchemaResponseFormat._;

  /// Any JSON object: `jsonSchema({'type': 'object'})`.
  factory ResponseFormat.jsonObject() =>
      ResponseFormat.jsonSchema(const {'type': 'object'});

  /// The keywords core validates, and the most any engine may enforce in
  /// this release.
  static const Set<String> dialect = {
    'type',
    'properties',
    'required',
    'additionalProperties',
    'items',
    'enum',
    'const',
    'minItems',
    'maxItems',
    'minLength',
    'maxLength',
    'minimum',
    'maximum',
    // annotations: kept, not validated
    'description',
    'title',
    'examples',
  };
}

/// A [ResponseFormat] of JSON values valid against [schema]. Made by
/// [ResponseFormat.jsonSchema] and [ResponseFormat.jsonObject].
final class JsonSchemaResponseFormat extends ResponseFormat {
  JsonSchemaResponseFormat._(Map<String, Object?> schema, {String? name})
    : this._checked(_copySchema(schema), name);

  JsonSchemaResponseFormat._checked(this.schema, this.name)
    : schemaJson = jsonEncode(schema),
      _canonical = jsonEncode(_sortedKeys(schema)),
      super._() {
    _checkSubschema(schema, '', 1, isRoot: true);
  }

  /// Unmodifiable deep copy, in the caller's key order.
  final Map<String, Object?> schema;

  /// The schema as JSON in the caller's key order: what engines send
  /// (grammars emit properties in schema order).
  final String schemaJson;

  /// Sent where an engine takes a name (llama); others ignore it.
  final String? name;

  /// The schema with its keys sorted, for [==] and [hashCode].
  final String _canonical;

  @override
  bool operator ==(Object other) =>
      other is JsonSchemaResponseFormat &&
      other._canonical == _canonical &&
      other.name == name;

  @override
  int get hashCode => Object.hash(_canonical, name);

  @override
  String toString() =>
      'ResponseFormat.jsonSchema($schemaJson${name == null ? '' : ', name: $name'})';
}

/// The annotation keywords of [ResponseFormat.dialect]: kept, never
/// validated, and an engine need not list them.
const Set<String> responseFormatAnnotations = {
  'description',
  'title',
  'examples',
};

const _types = {
  'object',
  'array',
  'string',
  'integer',
  'number',
  'boolean',
  'null',
};

const _maxDepth = 32;

/// A deep copy of [schema] that holds only JSON values (null, booleans,
/// finite numbers, strings, lists, maps with string keys), in the caller's
/// key order, made unmodifiable. Copied by hand, not through `jsonDecode`: on
/// the web that returns maps that put integer-like keys first.
Map<String, Object?> _copySchema(Map<String, Object?> schema) =>
    _copyJson(schema, '', <Object>{}) as Map<String, Object?>;

Object? _copyJson(Object? value, String path, Set<Object> open) {
  Never refuse(String problem) => throw ArgumentError.value(
    value,
    'schema',
    'is not JSON-encodable at ${path.isEmpty ? '/' : path}: $problem',
  );
  switch (value) {
    case null || bool() || String():
      return value;
    case num():
      if (!value.isFinite) refuse('$value is not a JSON number');
      return value;
    case List():
      if (!open.add(value)) refuse('the list contains itself');
      final copy = List<Object?>.unmodifiable([
        for (var i = 0; i < value.length; i++)
          _copyJson(value[i], '$path/$i', open),
      ]);
      open.remove(value);
      return copy;
    case Map():
      if (!open.add(value)) refuse('the map contains itself');
      final copy = <String, Object?>{};
      for (final MapEntry(:key, value: item) in value.entries) {
        if (key is! String) refuse('the key $key is not a string');
        copy[key] = _copyJson(item, '$path/${jsonPointerToken(key)}', open);
      }
      open.remove(value);
      return Map<String, Object?>.unmodifiable(copy);
    default:
      refuse('a ${value.runtimeType}');
  }
}

/// [value] with its keys sorted and its integral numbers written as
/// integers, so `1` and `1.0` compare equal on the VM as on the web.
Object? _sortedKeys(Object? value) => switch (value) {
  Map() => {
    for (final key in (value.keys.cast<String>().toList()..sort()))
      key: _sortedKeys(value[key]),
  },
  List() => [for (final item in value) _sortedKeys(item)],
  double()
      when value == value.truncateToDouble() &&
          value.abs() < 9007199254740992 =>
    value.toInt(),
  _ => value,
};

/// A JSON Pointer token for [key] (RFC 6901: `~` → `~0`, `/` → `~1`).
String jsonPointerToken(String key) =>
    key.replaceAll('~', '~0').replaceAll('/', '~1');

Never _malformed(String path, String problem) => throw ArgumentError(
  'Not a well-formed schema at ${path.isEmpty ? '/' : path}: $problem',
  'schema',
);

void _checkSubschema(
  Object? node,
  String path,
  int depth, {
  bool isRoot = false,
}) {
  if (depth > _maxDepth) {
    _malformed(path, 'nesting is deeper than $_maxDepth levels');
  }
  if (node is! Map<String, Object?>) {
    _malformed(path, 'a subschema must be a map, not ${jsonKindOf(node)}');
  }
  final type = node['type'];
  if (!node.containsKey('type')) {
    if (isRoot) _malformed(path, 'the root must declare a "type"');
  } else if (type is! String || !_types.contains(type)) {
    _malformed(
      '$path/type',
      '"type" must be one of ${_types.join(', ')}, as a single string '
          '(type arrays are refused)',
    );
  }

  final properties = node['properties'];
  if (node.containsKey('properties')) {
    if (properties is! Map<String, Object?>) {
      _malformed('$path/properties', '"properties" must be a map');
    }
    for (final entry in properties.entries) {
      _checkSubschema(
        entry.value,
        '$path/properties/${jsonPointerToken(entry.key)}',
        depth + 1,
      );
    }
  }

  if (node.containsKey('required')) {
    final required = node['required'];
    if (required is! List) {
      _malformed('$path/required', '"required" must be a list of names');
    }
    final seen = <String>{};
    for (final name in required) {
      if (name is! String) {
        _malformed('$path/required', '"required" must be a list of names');
      }
      if (!seen.add(name)) {
        _malformed('$path/required', '"$name" is listed twice');
      }
      if (properties is! Map || !properties.containsKey(name)) {
        _malformed('$path/required', '"$name" is not in "properties"');
      }
    }
  }

  if (node.containsKey('additionalProperties') &&
      node['additionalProperties'] != false) {
    _malformed(
      '$path/additionalProperties',
      '"additionalProperties" may only be false',
    );
  }

  if (node.containsKey('items')) {
    _checkSubschema(node['items'], '$path/items', depth + 1);
  }

  _checkBounds(node, path, 'minItems', 'maxItems', integer: true);
  _checkBounds(node, path, 'minLength', 'maxLength', integer: true);
  _checkBounds(node, path, 'minimum', 'maximum', integer: false);

  if (node.containsKey('enum')) {
    final values = node['enum'];
    if (values is! List || values.isEmpty) {
      _malformed('$path/enum', '"enum" must be a non-empty list');
    }
    for (var i = 0; i < values.length; i++) {
      for (var j = 0; j < i; j++) {
        if (jsonValuesEqual(values[i], values[j])) {
          _malformed('$path/enum', 'values $j and $i are equal');
        }
      }
    }
  }
  // `const` is any one JSON value, null included; the copy already made it
  // one.
}

void _checkBounds(
  Map<String, Object?> node,
  String path,
  String minKey,
  String maxKey, {
  required bool integer,
}) {
  num? read(String key) {
    if (!node.containsKey(key)) return null;
    final value = node[key];
    if (integer) {
      if (!isJsonInteger(value) || (value as num) < 0) {
        _malformed('$path/$key', '"$key" must be a non-negative integer');
      }
      return value;
    }
    if (value is! num || !value.isFinite) {
      _malformed('$path/$key', '"$key" must be a number');
    }
    return value;
  }

  final min = read(minKey);
  final max = read(maxKey);
  if (min != null && max != null && min > max) {
    _malformed('$path/$minKey', '"$minKey" ($min) is above "$maxKey" ($max)');
  }
}

/// The JSON kind of [value], for a message.
String jsonKindOf(Object? value) => switch (value) {
  null => 'null',
  bool() => 'a boolean',
  num() => 'a number',
  String() => 'a string',
  List() => 'an array',
  Map() => 'an object',
  _ => value.runtimeType.toString(),
};

/// Whether [value] is a JSON integer: a number with no fractional part
/// (`1.0` is one).
bool isJsonInteger(Object? value) =>
    value is int ||
    (value is double && value.isFinite && value == value.truncateToDouble());

/// Deep equality of two decoded JSON values: maps by their keys, lists in
/// order, numbers by value (`1 == 1.0`).
bool jsonValuesEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonValuesEqual(a[key], b[key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonValuesEqual(a[i], b[i])) return false;
    }
    return true;
  }
  // Numbers by value (`1 == 1.0`); strings, booleans and null as they are.
  return a == b;
}
