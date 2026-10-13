import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;

/// Reports the backend identity rather than the requested GPU layer budget.
edge.PreferredBackend? resolveBackend(
  String name,
  edge.PreferredBackend? requested,
) {
  final value = name.toLowerCase();
  final edge.PreferredBackend? backend;
  if (value.contains('cpu') || value.contains('wasm')) {
    backend = edge.PreferredBackend.cpu;
  } else if (value.contains('metal') ||
      value.contains('vulkan') ||
      value.contains('cuda') ||
      value.contains('webgpu') ||
      value.contains('gpu')) {
    backend = edge.PreferredBackend.gpu;
  } else {
    backend = null;
  }
  if (requested == edge.PreferredBackend.gpu &&
      backend == edge.PreferredBackend.cpu) {
    throw UnsupportedError(
      'GPU was requested but the runtime selected CPU. Install a compatible backend/driver or select CPU.',
    );
  }
  return backend;
}
