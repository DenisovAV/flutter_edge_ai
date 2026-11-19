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
