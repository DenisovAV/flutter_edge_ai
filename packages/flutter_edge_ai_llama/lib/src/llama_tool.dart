import 'dart:convert';

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
}

/// Keeps the complete JSON Schema instead of reducing it to scalar ToolParams.
class SchemaToolDefinition extends llama.ToolDefinition {
  /// Copies an Edge AI tool declaration into llamadart's template vocabulary.
  SchemaToolDefinition(edge.Tool tool)
    : schema = jsonDecode(jsonEncode(tool.parameters)) as Map<String, dynamic>,
      super(
        name: tool.name,
        description: tool.description,
        parameters: const [],
      ) {
    if (schema.isEmpty) schema.addAll({'type': 'object', 'properties': {}});
    if (name.trim().isEmpty || schema['type'] != 'object') {
      throw ArgumentError(
        'Tool names must be nonempty and parameters must be an object JSON Schema.',
      );
    }
  }

  /// A private copy of the supplied JSON Schema.
  final Map<String, dynamic> schema;

  @override
  Map<String, dynamic> toJsonSchema() =>
      jsonDecode(jsonEncode(schema)) as Map<String, dynamic>;
}
