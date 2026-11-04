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
    final start = error.message.indexOf(r'$');
    return edge.ResponseFormatUnsupportedException(
      "llama.cpp's grammar cannot enforce this schema: ${error.message}",
      schemaPath: start < 0
          ? null
          : _pointer(schema, error.message.substring(start)),
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

/// The JSON Pointer of the llamadart path that starts [message]
/// (`$.properties.a.minLength is …`) in [schema]: `/properties/a/minLength`.
/// Property names may contain dots and spaces, so each is matched, longest
/// first, against the names [schema] declares; the path ends at the first
/// character no name or keyword explains. A path that ends on a subschema
/// names its integer bound when it has one (llamadart reports a bound it
/// cannot build on the subschema), else the subschema itself; the root is
/// null (the whole format).
String? _pointer(Map<String, dynamic> schema, String message) {
  var rest = message.substring(1);
  Object? node = schema;
  final tokens = <String>[];
  bool ends(String text) =>
      text.isEmpty || !RegExp(r'^[A-Za-z0-9_]').hasMatch(text);
  while (rest.startsWith('.') && rest.length > 1) {
    if (node is! Map) return null;
    rest = rest.substring(1);
    final properties = node['properties'];
    if (rest.startsWith('properties.') && properties is Map) {
      rest = rest.substring('properties.'.length);
      String? name;
      for (final key in properties.keys.cast<String>()) {
        if (rest.startsWith(key) &&
            ends(rest.substring(key.length)) &&
            key.length > (name?.length ?? -1)) {
          name = key;
        }
      }
      if (name == null) return null;
      tokens.addAll(['properties', name]);
      node = properties[name];
      rest = rest.substring(name.length);
    } else if (rest.startsWith('items') &&
        ends(rest.substring('items'.length)) &&
        node['items'] is Map) {
      tokens.add('items');
      node = node['items'];
      rest = rest.substring('items'.length);
    } else {
      final keyword = RegExp(r'^[A-Za-z]+').firstMatch(rest)?.group(0);
      if (keyword == null) return null;
      tokens.add(keyword);
      node = null;
      rest = '';
    }
  }
  if (node is Map) {
    final bound = ['minimum', 'maximum'].where(node.containsKey).firstOrNull;
    if (bound != null) tokens.add(bound);
  }
  if (tokens.isEmpty) return null;
  return tokens
      .map((token) => '/${token.replaceAll('~', '~0').replaceAll('/', '~1')}')
      .join();
}
