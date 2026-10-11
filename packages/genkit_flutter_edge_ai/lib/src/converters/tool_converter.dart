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
/// the schema is flattened first. One that cannot be, recursive or referring
/// to another document, is an INVALID_ARGUMENT.
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
  final Map<String, dynamic> flat;
  try {
    flat = Map<String, dynamic>.from(schema.flatten());
  } on FormatException catch (e) {
    throw GenkitException(
      'The input schema of tool "$tool" cannot be flattened: ${e.message}',
      status: StatusCode.invalidArgument,
    );
  }
  // flatten() resolves references into the schema's own `$defs` and leaves
  // any other (another document's URL, say) in place.
  if (_hasRefs(flat)) {
    throw GenkitException(
      'The input schema of tool "$tool" refers to a schema outside itself; '
      'inline it, the on-device model cannot resolve references.',
      status: StatusCode.invalidArgument,
    );
  }
  return flat;
}

bool _hasRefs(Object? node) => switch (node) {
  final Map<String, dynamic> map =>
    map.containsKey(r'$ref') ||
        map.containsKey(r'$defs') ||
        map.values.any(_hasRefs),
  final List<dynamic> list => list.any(_hasRefs),
  _ => false,
};
