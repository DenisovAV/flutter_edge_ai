import 'dart:collection';

/// [schema] as Genkit sends it, rewritten into the shape flutter_edge_ai's
/// `ResponseFormat` dialect takes: `$schema` dropped, every local `$ref`
/// (`#/$defs/<name>`, `#/definitions/<name>`) replaced by the definition it
/// names, and a single-element `allOf` replaced by its element. Genkit wraps
/// a schemantic type's schema in a reference
/// (`{"$ref": "#/$defs/Recipe", "$defs": {...}, "$schema": "..."}`), and
/// schemantic wraps a field carrying `@Field(description:)` in
/// `{"allOf": [{"$ref": ...}], "description": ...}`; the dialect refuses
/// both. Annotations beside a `$ref` or an `allOf` win over the
/// definition's own.
///
/// Only schema positions are walked (`properties`, `items`,
/// `additionalProperties`, `not`, `allOf`, `anyOf`, `oneOf`): the values of
/// `enum`, `const`, `examples` and every other keyword are data and are left
/// as they are, and a property may have any name.
///
/// Null when the schema cannot be inlined: a recursive type, a map or list
/// that contains itself, a reference to a definition that is not there or
/// outside the document, a `$ref` or `allOf` with other keywords beside it
/// than annotations, or a result above [_maxNodes] maps and lists (shared
/// definitions referenced again and again grow it exponentially). Such a
/// schema stays a prompt instruction.
Map<String, Object?>? inlineSchemaRefs(Map<String, dynamic> schema) {
  try {
    return _Inliner(schema).root();
  } on _NotInlinable {
    return null;
  }
}

/// The most maps and lists an inlined schema may have, counting a shared
/// definition once per reference.
const _maxNodes = 10000;

/// The annotations a `$ref` or a single-element `allOf` may carry beside it.
const _annotations = {'description', 'title', 'examples'};

/// Keywords whose value is one subschema.
const _subschemaKeywords = {'items', 'additionalProperties', 'not'};

/// Keywords whose value is a list of subschemas.
const _subschemaListKeywords = {'allOf', 'anyOf', 'oneOf'};

final class _Inliner {
  _Inliner(this._document);

  final Map<String, dynamic> _document;

  /// The maps and lists on the path being walked, by identity.
  final _open = LinkedHashSet<Object>.identity();

  /// Each definition already inlined, with how many nodes it counts for.
  final _inlined =
      LinkedHashMap<Object, (Map<String, Object?>, int)>.identity();

  int _nodes = 0;

  Map<String, Object?> root() {
    final root = {
      for (final MapEntry(:key, :value) in _document.entries)
        if (key != r'$schema' && key != r'$defs' && key != 'definitions')
          key: value,
    };
    // Walked under the document's identity, so a document that contains
    // itself is caught.
    return _enter(_document, () => _schemaMap(root));
  }

  T _enter<T>(Object node, T Function() walk) {
    if (!_open.add(node)) throw const _NotInlinable();
    if (++_nodes > _maxNodes) throw const _NotInlinable();
    try {
      return walk();
    } finally {
      _open.remove(node);
    }
  }

  /// [node] in a schema position.
  Object? _schema(Object? node) {
    if (node is! Map) return node;
    return _enter(node, () => _schemaMap(node.cast<String, Object?>()));
  }

  Map<String, Object?> _schemaMap(Map<String, Object?> map) {
    final ref = map[r'$ref'];
    if (ref != null) {
      return _withAnnotations(_resolve(ref), map, r'$ref');
    }
    final allOf = map['allOf'];
    if (allOf is List && allOf.length == 1) {
      final siblings = {...map.keys}..remove('allOf');
      if (_annotations.containsAll(siblings)) {
        final inner = _enter(allOf, () => _schema(allOf.single));
        if (inner is! Map<String, Object?>) throw const _NotInlinable();
        return _withAnnotations(inner, map, 'allOf');
      }
    }
    return {
      for (final MapEntry(:key, :value) in map.entries)
        key: _keyword(key, value),
    };
  }

  Object? _keyword(String key, Object? value) {
    if (key == 'properties' && value is Map) {
      return _enter(value, () {
        return {
          for (final MapEntry(:key, :value) in value.entries)
            key: _schema(value),
        };
      });
    }
    if (_subschemaKeywords.contains(key)) return _schema(value);
    if (_subschemaListKeywords.contains(key) && value is List) {
      return _enter(value, () => [for (final item in value) _schema(item)]);
    }
    // Data: enum, const, examples, and keywords the dialect refuses anyway.
    return value;
  }

  /// [target] with the annotations beside [wrapper] in [map], which win.
  Map<String, Object?> _withAnnotations(
    Map<String, Object?> target,
    Map<String, Object?> map,
    String wrapper,
  ) {
    final siblings = {...map.keys}..remove(wrapper);
    if (!_annotations.containsAll(siblings)) throw const _NotInlinable();
    // Shared as it is, so a definition referenced again costs no copy.
    if (siblings.isEmpty) return target;
    return {...target, for (final key in siblings) key: map[key]};
  }

  Map<String, Object?> _resolve(Object? ref) {
    final definition = _definition(ref);
    if (_inlined[definition] case (final inlined, final size)) {
      _nodes += size;
      if (_nodes > _maxNodes) throw const _NotInlinable();
      return inlined;
    }
    final before = _nodes;
    final inlined = _schema(definition);
    if (inlined is! Map<String, Object?>) throw const _NotInlinable();
    _inlined[definition] = (inlined, _nodes - before);
    return inlined;
  }

  /// The definition [ref] points at: `#/$defs/<name>` or
  /// `#/definitions/<name>`, the name one JSON Pointer token in a URI
  /// fragment (percent-decoded, then `~1` read as `/` and `~0` as `~`,
  /// RFC 6901).
  Map<Object?, Object?> _definition(Object? ref) {
    if (ref is! String) throw const _NotInlinable();
    for (final container in const [r'$defs', 'definitions']) {
      final prefix = '#/$container/';
      if (!ref.startsWith(prefix)) continue;
      final String token;
      try {
        token = Uri.decodeComponent(ref.substring(prefix.length));
      } on ArgumentError {
        throw const _NotInlinable();
      }
      // A deeper pointer than one definition.
      if (token.contains('/')) throw const _NotInlinable();
      final name = token.replaceAll('~1', '/').replaceAll('~0', '~');
      final definitions = _document[container];
      final definition = definitions is Map ? definitions[name] : null;
      if (definition is! Map) throw const _NotInlinable();
      return definition;
    }
    throw const _NotInlinable();
  }
}

final class _NotInlinable implements Exception {
  const _NotInlinable();
}
