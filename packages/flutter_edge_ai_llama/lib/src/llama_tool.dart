import 'dart:convert';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

/// Keeps the complete JSON Schema instead of reducing it to scalar ToolParams.
class SchemaToolDefinition extends llama.ToolDefinition {
  /// Copies an Edge AI tool declaration into llamadart's template vocabulary.
  factory SchemaToolDefinition(edge.Tool tool) {
    final schema =
        jsonDecode(jsonEncode(tool.parameters)) as Map<String, dynamic>;
    if (schema.isEmpty) {
      schema.addAll({'type': 'object', 'properties': <String, dynamic>{}});
    }
    if (tool.name.trim().isEmpty || schema['type'] != 'object') {
      throw ArgumentError(
        'Tool names must be nonempty and parameters must be an object JSON Schema.',
      );
    }
    return SchemaToolDefinition._(tool, schema, _properties(schema));
  }

  SchemaToolDefinition._(
    edge.Tool tool,
    this.schema,
    List<llama.ToolParam>? parameters,
  ) : _typable = parameters != null,
      super(
        name: tool.name,
        description: tool.description,
        parameters: parameters ?? const [],
      );

  final bool _typable;

  /// XML grammars derive one parameter-name union for the whole tool set.
  /// Partial typed views would forbid names from the untypable tools.
  static List<SchemaToolDefinition> fromTools(List<edge.Tool> tools) {
    final definitions = tools.map(SchemaToolDefinition.new).toList();
    if (definitions.every((tool) => tool._typable)) return definitions;
    return [
      for (var i = 0; i < definitions.length; i++)
        SchemaToolDefinition._(tools[i], definitions[i].schema, null),
    ];
  }

  /// Specialized SDK grammars must not silently discard constraints missing
  /// from their typed-parameter view. Other handlers use the complete schema.
  bool get requiresFullSchema =>
      jsonEncode(_canonical(schema)) !=
      jsonEncode(_canonical(super.toJsonSchema()));

  /// A private copy of the supplied JSON Schema.
  final Map<String, dynamic> schema;

  @override
  Map<String, dynamic> toJsonSchema() =>
      jsonDecode(jsonEncode(schema)) as Map<String, dynamic>;
}

List<llama.ToolParam>? _properties(Map<String, dynamic> schema) {
  final raw = schema.containsKey('properties')
      ? schema['properties']
      : <String, dynamic>{};
  if (raw is! Map<String, dynamic>) {
    throw ArgumentError('Schema properties must be an object.');
  }
  final required = schema.containsKey('required')
      ? schema['required']
      : const <String>[];
  if (required is! List || required.any((name) => name is! String)) {
    throw ArgumentError('Schema required must be a list of strings.');
  }
  var typable = required.every(raw.containsKey);
  final parameters = <llama.ToolParam>[];
  for (final entry in raw.entries) {
    if (entry.value is bool) {
      typable = false;
      continue;
    }
    if (entry.value is! Map<String, dynamic>) {
      throw ArgumentError(
        'Schema properties must be object or boolean schemas.',
      );
    }
    final parameter = _parameter(
      entry.key,
      entry.value as Map<String, dynamic>,
      required.contains(entry.key),
    );
    if (parameter == null || entry.key.isEmpty) {
      typable = false;
    } else {
      parameters.add(parameter);
    }
  }
  return typable ? parameters : null;
}

llama.ToolParam? _parameter(
  String name,
  Map<String, dynamic> schema,
  bool required,
) {
  final description = schema['description'] as String?;
  final values = schema['enum'];
  if (values != null) {
    if (values is! List ||
        values.isEmpty ||
        values.any((value) => value is! String)) {
      return null;
    }
    return llama.ToolParam.enumType(
      name,
      values: values.cast<String>(),
      description: description,
      required: required,
    );
  }
  return switch (schema['type']) {
    'string' => llama.ToolParam.string(
      name,
      description: description,
      required: required,
    ),
    'integer' => llama.ToolParam.integer(
      name,
      description: description,
      required: required,
    ),
    'number' => llama.ToolParam.number(
      name,
      description: description,
      required: required,
    ),
    'boolean' => llama.ToolParam.boolean(
      name,
      description: description,
      required: required,
    ),
    'null' => llama.ToolParam.nullType(
      name,
      description: description,
      required: required,
    ),
    'object' => switch (_properties(schema)) {
      final List<llama.ToolParam> properties => llama.ToolParam.object(
        name,
        properties: properties,
        description: description,
        required: required,
      ),
      _ => null,
    },
    'array' => switch (schema['items']) {
      final Map<String, dynamic> items => switch (_parameter(
        'item',
        items,
        false,
      )) {
        final llama.ToolParam item => llama.ToolParam.array(
          name,
          itemType: item,
          description: description,
          required: required,
        ),
        _ => null,
      },
      _ => null,
    },
    _ => null,
  };
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys =
        value.keys
            .cast<String>()
            .where(
              (key) =>
                  key != 'description' && key != 'title' && key != r'$schema',
            )
            .toList()
          ..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

/// Returns an actionable refusal reason when [format] and [toolChoice] cannot
/// enforce the supplied [tools]' JSON Schema constraints, or null when valid.
String? toolPreflightRefusal(
  List<SchemaToolDefinition> tools, {
  required int format,
  required llama.ToolChoice toolChoice,
  bool lfm2ForcesJson = false,
}) {
  if (toolChoice == llama.ToolChoice.none) return null;
  if (format == llama.ChatFormat.qwen3CoderXml.index) {
    for (final tool in tools) {
      final refusal = _qwen3CoderXmlViolation(tool);
      if (refusal != null) return refusal;
    }
    return null;
  }
  if (format == llama.ChatFormat.lfm2.index &&
      toolChoice == llama.ToolChoice.auto &&
      !lfm2ForcesJson) {
    for (final tool in tools) {
      final refusal = _checkLfm2AutoNode(
        tool.schema,
        path: tool.name,
        isRoot: true,
      );
      if (refusal != null) return refusal;
    }
    return null;
  }
  if (format == llama.ChatFormat.seedOss.index) {
    for (final tool in tools) {
      final refusal = _checkSeedOssNode(
        tool.schema,
        tool.schema,
        path: tool.name,
        seenRefs: <String>{},
      );
      if (refusal != null) return refusal;
    }
  }
  return null;
}

const _annotationKeys = {
  r'$schema',
  r'$id',
  r'$comment',
  'title',
  'description',
  'default',
  'examples',
  'deprecated',
  'readOnly',
  'writeOnly',
};

String? _firstDisallowedKeyword(
  Map<String, dynamic> schema,
  Set<String> allowed,
) {
  for (final key in schema.keys) {
    if (!allowed.contains(key) &&
        !_annotationKeys.contains(key) &&
        !key.startsWith('x-')) {
      return key;
    }
  }
  return null;
}

/// Mirrors llamadart's `mayBeString` for Qwen3-Coder XML top-level arguments:
/// string-capable top-level values use an unconstrained XML text rule.
bool _mayBeString(Map<String, dynamic> schema) {
  final type = schema['type'];
  if (type is String) return type == 'string';
  if (type is List) return type.contains('string');
  if (schema.containsKey('const')) return schema['const'] is String;
  final values = schema['enum'];
  if (values is List) return values.any((value) => value is String);
  for (final key in const ['anyOf', 'oneOf']) {
    final children = schema[key];
    if (children is List) {
      return children.any(
        (child) =>
            child is! Map || _mayBeString(Map<String, dynamic>.from(child)),
      );
    }
  }
  final children = schema['allOf'];
  if (children is List) {
    return children.every(
      (child) =>
          child is! Map || _mayBeString(Map<String, dynamic>.from(child)),
    );
  }
  return true;
}

String? _qwen3CoderXmlViolation(SchemaToolDefinition tool) {
  final rawProps = tool.schema['properties'];
  if (rawProps is! Map) return null;
  for (final entry in rawProps.entries) {
    final propName = entry.key;
    if (propName is! String) continue;
    final propSchema = entry.value;
    if (propSchema is bool) {
      if (!propSchema) {
        return 'Qwen3-Coder XML tool grammar does not enforce boolean schema '
            '"false" on top-level parameter "$propName" of tool "${tool.name}". '
            'Use an unconstrained string parameter, an integer enum, or a nested schema.';
      }
      continue;
    }
    if (propSchema is! Map<String, dynamic>) continue;
    if (!_mayBeString(propSchema)) continue;
    final offending = _firstDisallowedKeyword(propSchema, const {'type'});
    if (offending != null) {
      return 'Qwen3-Coder XML tool grammar does not enforce "$offending" on '
          'top-level string-capable parameter "$propName" of tool "${tool.name}". '
          'Use an unconstrained string parameter, an integer enum, or a nested object/array schema.';
    }
  }
  return null;
}

String? _checkLfm2AutoNode(
  Object? node, {
  required String path,
  bool isRoot = false,
}) {
  if (node is! Map<String, dynamic>) return null;
  final type = node['type'];
  final values = node['enum'];
  final allowed = <String>{
    'type',
    if (values is List &&
        values.isNotEmpty &&
        values.every((v) => v is String) &&
        (type == null || type == 'string'))
      'enum',
    if (type == 'object') ...['properties', 'required'],
    if (type == 'object' && node['additionalProperties'] is bool)
      'additionalProperties',
    if (type == 'array') 'items',
    if (isRoot) ...[r'$defs', 'definitions'],
  };
  final keyword = _firstDisallowedKeyword(node, allowed);
  if (keyword != null) {
    return 'LFM2 auto tool grammar cannot enforce "$keyword" at "$path". Use ToolChoice.required or another model format.';
  }
  final properties = node['properties'];
  if (properties is Map) {
    for (final entry in properties.entries) {
      final error = _checkLfm2AutoNode(
        entry.value,
        path: '$path.properties.${entry.key}',
      );
      if (error != null) return error;
    }
  }
  return _checkLfm2AutoNode(node['items'], path: '$path.items');
}

String? _checkSeedOssNode(
  Object? node,
  Map<String, dynamic> root, {
  required String path,
  required Set<String> seenRefs,
}) {
  if (node is! Map<String, dynamic>) return null;
  for (final keyword in ['enum', 'pattern']) {
    if (node.containsKey(keyword)) {
      return 'Seed-OSS tool grammar cannot enforce "$keyword" at "$path". Use another model format.';
    }
  }
  String? check(Object? child, String key) =>
      _checkSeedOssNode(child, root, path: '$path.$key', seenRefs: seenRefs);
  final ref = node[r'$ref'];
  if (ref is String && seenRefs.add(ref)) {
    final error = check(_resolveLocalPointer(root, ref), ref);
    if (error != null) return error;
  }
  for (final key in ['properties', 'patternProperties', 'dependentSchemas']) {
    final children = node[key];
    if (children is Map) {
      for (final entry in children.entries) {
        final error = check(entry.value, '$key.${entry.key}');
        if (error != null) return error;
      }
    }
  }
  for (final key in [
    'items',
    'prefixItems',
    'contains',
    'additionalItems',
    'additionalProperties',
    'propertyNames',
    'unevaluatedProperties',
    'unevaluatedItems',
    'allOf',
    'anyOf',
    'oneOf',
    'not',
    'if',
    'then',
    'else',
  ]) {
    final child = node[key];
    if (child == null) continue;
    for (final schema in child is List ? child : [child]) {
      final error = check(schema, key);
      if (error != null) return error;
    }
  }
  return null;
}

Object? _resolveLocalPointer(Map<String, dynamic> root, String ref) {
  if (!ref.startsWith('#/')) return null;
  Object? current = root;
  for (final raw in ref.substring(2).split('/')) {
    final segment = raw.replaceAll('~1', '/').replaceAll('~0', '~');
    if (current is Map) {
      if (!current.containsKey(segment)) return null;
      current = current[segment];
    } else if (current is List) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
    } else {
      return null;
    }
  }
  return current;
}
