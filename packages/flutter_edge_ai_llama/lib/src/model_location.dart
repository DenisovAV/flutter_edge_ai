import 'package:flutter_edge_ai/engine.dart';

/// Native core has already resolved the primary model to a local path.
Future<String> resolveModelLocation(
  ModelSpec spec,
  RuntimeConfig config,
) async => config.modelPath;
