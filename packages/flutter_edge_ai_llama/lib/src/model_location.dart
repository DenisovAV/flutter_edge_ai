import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';

/// Native core has already resolved the primary model to a local path.
Future<String> resolveModelLocation(
  ModelSpec spec,
  RuntimeConfig config,
) async => config.modelPath;

/// Native core supplies the real inference identity to its provider.
InferenceModelSpec resolveInferenceSpec(InferenceModelSpec spec) => spec;
