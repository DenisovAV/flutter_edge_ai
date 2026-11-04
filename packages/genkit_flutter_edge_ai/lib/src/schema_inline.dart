/// [schema] as Genkit sends it, rewritten into the shape flutter_edge_ai's
/// `ResponseFormat` dialect takes: `$schema` dropped, and every local `$ref`
/// (`#/$defs/<name>`, `#/definitions/<name>`) replaced by the definition it
/// names. Genkit wraps a schemantic type's schema that way
/// (`{"$ref": "#/$defs/Recipe", "$defs": {...}, "$schema": "..."}`), which the
/// dialect refuses at its root.
///
/// Null when the schema cannot be inlined: a recursive type, a reference to
/// a definition that is not there or outside the document, or a `$ref` with
/// other keywords beside it than annotations. Such a schema stays a prompt
/// instruction.
Map<String, Object?>? inlineSchemaRefs(Map<String, dynamic> schema) {
  final definitions = <String, Map<String, Object?>>{};
  for (final prefix in const [r'$defs', 'definitions']) {
    final defs = schema[prefix];
    if (defs == null) continue;
    if (defs is! Map) return null;
    for (final MapEntry(:key, :value) in defs.entries) {
      if (value is! Map) return null;
      definitions['#/$prefix/$key'] = value.cast<String, Object?>();
    }
  }

  final root = {
    for (final MapEntry(:key, :value) in schema.entries)
      if (key != r'$schema' && key != r'$defs' && key != 'definitions')
        key: value,
  };
  try {
    return _inline(root, definitions, const {}) as Map<String, Object?>;
  } on _NotInlinable {
    return null;
  }
}

/// The annotations a `$ref` may carry beside it; they are kept, and win over
/// the definition's own.
const _refAnnotations = {'description', 'title', 'examples'};

Object? _inline(
  Object? node,
  Map<String, Map<String, Object?>> definitions,
  Set<String> resolving,
) {
  if (node is List) {
    return [for (final item in node) _inline(item, definitions, resolving)];
  }
  if (node is! Map) return node;
  final map = node.cast<String, Object?>();
  final ref = map[r'$ref'];
  if (ref == null) {
    return {
      for (final MapEntry(:key, :value) in map.entries)
        // Values under `enum`, `const` and `examples` are data, not schemas.
        key: switch (key) {
          'enum' || 'const' || 'examples' => value,
          _ => _inline(value, definitions, resolving),
        },
    };
  }
  if (ref is! String || resolving.contains(ref)) throw const _NotInlinable();
  final definition = definitions[ref];
  if (definition == null) throw const _NotInlinable();
  final siblings = {...map.keys}..remove(r'$ref');
  if (!_refAnnotations.containsAll(siblings)) throw const _NotInlinable();
  final inlined =
      _inline(definition, definitions, {...resolving, ref})
          as Map<String, Object?>;
  return {...inlined, for (final key in siblings) key: map[key]};
}

final class _NotInlinable implements Exception {
  const _NotInlinable();
}
