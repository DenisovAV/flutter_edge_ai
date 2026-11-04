import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;

/// The Web backends on which the discriminating structured output run
/// passed: WebGPU in Chrome on macOS arm64 (2026-11-04, bridge assets
/// v0.1.79, SmolLM2 135M). Wasm has not run.
const Set<edge.PreferredBackend> structuredOutputQualifiedWebBackends = {
  edge.PreferredBackend.gpu,
};

/// Why a response format is refused in this browser for a model loaded on
/// [backend], or null when it has run there.
String? structuredOutputHostRefusal(edge.PreferredBackend? backend) {
  if (backend != null &&
      structuredOutputQualifiedWebBackends.contains(backend)) {
    return null;
  }
  return 'GGUF response formats have not been run on the Web'
      '${backend == null ? '' : ' with the ${backend.name} backend'} yet; '
      'they are refused there until they have.';
}
