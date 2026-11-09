import 'dart:ffi';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;

/// The native hosts and backends on which the discriminating structured
/// output run passed (`native structured output` in
/// `test/native_capabilities_test.dart`): macOS arm64 CPU and Metal
/// (2026-11-04; Qwen2.5 1.5B, Gemma 4 E2B on CPU, SmolLM2 135M). A response
/// format is enabled only after its own run, so every other host and backend
/// refuses it until one passes there.
const Map<Abi, Set<edge.PreferredBackend>> structuredOutputQualifiedHosts = {
  Abi.macosArm64: {edge.PreferredBackend.cpu, edge.PreferredBackend.gpu},
};

/// Why a response format is refused on this host for a model loaded on
/// [backend], or null when it has run here. Src-only seam: [abi] is for
/// tests.
String? structuredOutputHostRefusal(
  edge.PreferredBackend? backend, {
  Abi? abi,
}) {
  final host = abi ?? Abi.current();
  if (backend == null) {
    return 'The GGUF runtime did not report which device runs this model, '
        'so no response format is enforced on it.';
  }
  if (structuredOutputQualifiedHosts[host]?.contains(backend) ?? false) {
    return null;
  }
  return 'GGUF response formats have not been run on $host with the '
      '${backend.name} backend yet; they are refused there until they have.';
}
