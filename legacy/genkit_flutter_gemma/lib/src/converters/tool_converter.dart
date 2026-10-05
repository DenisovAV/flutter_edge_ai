import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:genkit/plugin.dart';

/// Converts Genkit [ToolDefinition] list to flutter_gemma [gemma.Tool] list.
///
/// Maps:
/// - `ToolDefinition.name` → `Tool.name`
/// - `ToolDefinition.description` → `Tool.description`
/// - `ToolDefinition.inputSchema` → `Tool.parameters` (JSON Schema)
List<gemma.Tool> convertTools(List<ToolDefinition>? tools) {
  if (tools == null || tools.isEmpty) return const [];

  return tools.map((tool) {
    return gemma.Tool(
      name: tool.name,
      description: tool.description,
      parameters: tool.inputSchema ?? const {},
    );
  }).toList();
}
