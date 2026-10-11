import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';
import 'package:schemantic/schemantic.dart' show SchemaFlatten;

/// Converts Genkit [ToolDefinition] list to flutter_edge_ai [gemma.Tool] list.
///
/// Maps:
/// - `ToolDefinition.name` → `Tool.name`
/// - `ToolDefinition.description` → `Tool.description`
/// - `ToolDefinition.inputSchema` → `Tool.parameters` (JSON Schema)
///
/// Genkit describes a tool whose input is a named `@Schema` type as a `$ref`
/// into `$defs`. Nothing between here and the model resolves references, so
/// the schema is flattened first; a recursive one cannot be, and is an
/// INVALID_ARGUMENT.
List<gemma.Tool> convertTools(List<ToolDefinition>? tools) {
  if (tools == null || tools.isEmpty) return const [];

  return tools.map((tool) {
    return gemma.Tool(
      name: tool.name,
      description: tool.description,
      parameters: _withoutRefs(tool.name, tool.inputSchema),
    );
  }).toList();
}

Map<String, dynamic> _withoutRefs(String tool, Map<String, dynamic>? schema) {
  if (schema == null) return const {};
  if (!_hasRefs(schema)) return schema;
  try {
    return Map<String, dynamic>.from(schema.flatten());
  } on FormatException catch (e) {
    throw GenkitException(
      'The input schema of tool "$tool" cannot be flattened: ${e.message}',
      status: StatusCode.invalidArgument,
    );
  }
}

bool _hasRefs(Object? node) => switch (node) {
  final Map<String, dynamic> map =>
    map.containsKey(r'$ref') ||
        map.containsKey(r'$defs') ||
        map.values.any(_hasRefs),
  final List<dynamic> list => list.any(_hasRefs),
  _ => false,
};
