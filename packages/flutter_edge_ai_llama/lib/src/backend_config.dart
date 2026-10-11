import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

/// Reports only verified offload; an explicit GPU request cannot become CPU.
edge.PreferredBackend? resolveBackend(
  int? gpuLayers,
  edge.PreferredBackend? requested,
) {
  if (requested == edge.PreferredBackend.gpu && gpuLayers == 0) {
    throw llama.LlamaUnsupportedException(
      'GPU was requested but the runtime loaded zero GPU layers. '
      'Install a compatible GPU backend/driver or explicitly select CPU.',
    );
  }
  return gpuLayers == null
      ? null
      : gpuLayers > 0
      ? edge.PreferredBackend.gpu
      : edge.PreferredBackend.cpu;
}
