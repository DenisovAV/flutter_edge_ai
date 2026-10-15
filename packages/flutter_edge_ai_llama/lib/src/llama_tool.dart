import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

/// A tool call retaining llamadart's identifier across the Edge AI boundary.
final class LlamaFunctionCallResponse extends edge.FunctionCallResponse {
  /// Creates a typed call with an identifier usable in [LlamaToolResponseMessage].
  const LlamaFunctionCallResponse({
    required this.id,
    required super.name,
    required super.args,
  });

  /// Call identifier, unique within the originating session.
  final String id;
}

/// A tool result explicitly associated with one call, including repeated names.
final class LlamaToolResponseMessage extends edge.Message {
  /// Encodes [response] as the result of [callId] and [toolName].
  LlamaToolResponseMessage({
    required this.callId,
    required String toolName,
    required Map<String, dynamic> response,
  }) : super(
         text: jsonEncode(response),
         toolName: toolName,
         type: edge.MessageType.toolResponse,
         isUser: true,
       );

  /// The identifier on [LlamaFunctionCallResponse].
  final String callId;

  LlamaToolResponseMessage._({
    required this.callId,
    required super.text,
    required super.isUser,
    super.imageBytes,
    super.images,
    super.audioBytes,
    required super.type,
    required super.toolName,
  });

  @override
  LlamaToolResponseMessage copyWith({
    String? text,
    bool? isUser,
    Uint8List? imageBytes,
    List<Uint8List>? images,
    Uint8List? audioBytes,
    edge.MessageType? type,
    String? toolName,
  }) => LlamaToolResponseMessage._(
    callId: callId,
    text: text ?? this.text,
    isUser: isUser ?? this.isUser,
    imageBytes: imageBytes ?? this.imageBytes,
    images: images ?? this.images,
    audioBytes: audioBytes ?? this.audioBytes,
    type: type ?? this.type,
    toolName: toolName ?? this.toolName,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlamaToolResponseMessage &&
          callId == other.callId &&
          super == other;

  @override
  int get hashCode => Object.hash(super.hashCode, callId);
}

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
    return SchemaToolDefinition._(
      tool,
      schema,
      _properties(schema) ?? const [],
    );
  }

  SchemaToolDefinition._(
    edge.Tool tool,
    this.schema,
    List<llama.ToolParam> parameters,
  ) : super(
        name: tool.name,
        description: tool.description,
        parameters: parameters,
      );

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
  final raw = schema['properties'] ?? <String, dynamic>{};
  if (raw is! Map<String, dynamic>) {
    throw ArgumentError('Schema properties must be an object.');
  }
  final required = schema['required'] ?? const <String>[];
  if (required is! List ||
      required.any((name) => name is! String || !raw.containsKey(name))) {
    throw ArgumentError('Schema required must name declared properties.');
  }
  final parameters = <llama.ToolParam>[];
  for (final entry in raw.entries) {
    if (entry.key.isEmpty || entry.value is! Map<String, dynamic>) {
      throw ArgumentError(
        'Schema properties need nonempty names and object schemas.',
      );
    }
    final parameter = _parameter(
      entry.key,
      entry.value as Map<String, dynamic>,
      required.contains(entry.key),
    );
    if (parameter == null) return null;
    parameters.add(parameter);
  }
  return parameters;
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
