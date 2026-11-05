import 'dart:convert';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

/// The `responseFormat` llamadart's `create` takes for [format]: a strict
/// `json_schema` with the schema in the caller's key order (the grammar
/// emits properties in that order) and the format's name, if any.
Map<String, dynamic> llamaResponseFormat(
  edge.JsonSchemaResponseFormat format,
) => {
  'type': 'json_schema',
  'json_schema': {
    'schema': _mutableSchema(format),
    'name': ?format.name,
    'strict': true,
  },
};

/// Why llamadart's JSON-schema-to-GBNF converter cannot enforce [format], or
/// null when it can.
///
/// The format is already in core's dialect; this is what the pinned
/// llamadart refuses within it: `minimum`/`maximum` on a `number`, a
/// one-sided integer bound its suffix builder cannot express, a length or
/// item bound above 2000, an `enum` or `const` beside another assertion, and
/// an `enum`/`const` value of another type than `type`. Its own validator
/// decides, so a llamadart upgrade that widens the subset widens this too.
edge.ResponseFormatUnsupportedException? llamaSchemaRefusal(
  edge.JsonSchemaResponseFormat format,
) {
  final schema = _mutableSchema(format);
  try {
    llama.LlamaStructuredOutput<Object?>.jsonValueSchema(
      schema: schema,
      decoder: (value) => value,
    );
    return null;
  } on llama.LlamaException catch (error) {
    return edge.ResponseFormatUnsupportedException(
      "llama.cpp's grammar cannot enforce this schema: ${error.message}",
      schemaPath: _pointer(schema, error.message),
    );
  }
}

/// [format]'s schema as llamadart reads it. Core's dialect takes a length or
/// item bound written `2.0`; llamadart's validator wants an `int`, so those
/// are written as one.
Map<String, dynamic> _mutableSchema(edge.JsonSchemaResponseFormat format) {
  final schema = jsonDecode(format.schemaJson) as Map<String, dynamic>;
  void normalize(Object? node) {
    if (node is! Map<String, dynamic>) return;
    for (final key in const [
      'minItems',
      'maxItems',
      'minLength',
      'maxLength',
    ]) {
      final value = node[key];
      if (value is double) node[key] = value.toInt();
    }
    final properties = node['properties'];
    if (properties is Map<String, dynamic>) {
      properties.values.forEach(normalize);
    }
    normalize(node['items']);
  }

  normalize(schema);
  return schema;
}

/// The JSON Pointer of the llamadart path in [message]
/// (`$.properties.a.minLength is …`) in [schema]: `/properties/a/minLength`.
///
/// Property names may contain dots and spaces, so a path can be read more
/// than one way (`a.b` the name, or `a` then `b`). Every reading is tried,
/// longest name first, and one counts only if it ends on a keyword that
/// subschema has, or on a subschema. A path that ends on a subschema names
/// the keyword llamadart refused there: the length, item or object keyword
/// a typeless subschema has, or the integer bound it cannot build; else the
/// subschema itself. The root alone is null (the whole format).
String? _pointer(Map<String, dynamic> schema, String message) {
  final start = message.indexOf(r'$');
  if (start < 0) return null;
  final tokens = _resolve(schema, message.substring(start + 1), message);
  if (tokens == null || tokens.isEmpty) return null;
  return tokens
      .map((token) => '/${token.replaceAll('~', '~0').replaceAll('/', '~1')}')
      .join();
}

/// The tokens of [rest], the part of llamadart's path after [node], or null
/// when no reading of it names something [node] has.
List<String>? _resolve(
  Map<dynamic, dynamic> node,
  String rest,
  String message,
) {
  if (!rest.startsWith('.') || rest.length == 1) {
    return [?_refusedKeywordAt(node, message)];
  }
  rest = rest.substring(1);
  final properties = node['properties'];
  if (rest.startsWith('properties.') && properties is Map) {
    final after = rest.substring('properties.'.length);
    final names =
        properties.keys
            .cast<String>()
            .where(
              (name) =>
                  after.startsWith(name) &&
                  _pathEnds(after.substring(name.length)),
            )
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    for (final name in names) {
      final child = properties[name];
      if (child is! Map) continue;
      final tail = _resolve(child, after.substring(name.length), message);
      if (tail != null) return ['properties', name, ...tail];
    }
  }
  final items = node['items'];
  if (rest.startsWith('items') &&
      _pathEnds(rest.substring('items'.length)) &&
      items is Map) {
    final tail = _resolve(items, rest.substring('items'.length), message);
    if (tail != null) return ['items', ...tail];
  }
  final keyword = RegExp(r'^[A-Za-z]+').firstMatch(rest)?.group(0);
  if (keyword != null &&
      node.containsKey(keyword) &&
      _pathEnds(rest.substring(keyword.length))) {
    return [keyword];
  }
  return null;
}

/// Whether a path segment ends where [text] starts.
bool _pathEnds(String text) =>
    text.isEmpty || !RegExp(r'^[A-Za-z0-9_]').hasMatch(text);

/// The keyword llamadart refused on a subschema it named as a whole.
String? _refusedKeywordAt(Map<dynamic, dynamic> node, String message) {
  final candidates = message.contains('string length keyword')
      ? const ['minLength', 'maxLength', 'pattern', 'format']
      : message.contains('array keyword')
      ? const ['items', 'minItems', 'maxItems']
      : message.contains('object keyword')
      ? const ['properties', 'required', 'additionalProperties']
      : const ['minimum', 'maximum'];
  return candidates.where(node.containsKey).firstOrNull;
}
