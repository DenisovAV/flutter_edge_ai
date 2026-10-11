import 'package:flutter_edge_ai/core/model_management/managers/web_model_manager.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart';

/// Uses core's installed blob/network URL rather than downloading the spec again.
Future<String> resolveModelLocation(
  ModelSpec spec,
  RuntimeConfig config,
) async {
  if (config.modelPath.isNotEmpty) return _urlLocation(config.modelPath);
  final manager = WebModelManager();
  await manager.ensureInitialized();
  final paths = await manager.getModelFilePaths(spec);
  final primary = paths?[spec.files.first.prefsKey];
  if (primary == null || primary.isEmpty) {
    throw LlamaStateException(
      'Install and activate the GGUF model before loading it.',
    );
  }
  return _urlLocation(primary);
}

String _urlLocation(String primary) {
  if (primary.startsWith('opfs://')) {
    throw LlamaUnsupportedException(
      'llamadart accepts model URLs, not Edge AI OPFS streams. '
      'Initialize Flutter Edge AI with WebStorageMode.cacheApi or none.',
    );
  }
  return primary;
}

/// Core Web probes a synthetic binary spec; recover the activated identity.
InferenceModelSpec resolveInferenceSpec(InferenceModelSpec spec) {
  if (spec.name == 'web-active' &&
      spec.modelSource is edge.AssetSource &&
      spec.files.first.filename == 'active.bin') {
    final active =
        edge.FlutterEdgeAiPlugin.instance.modelManager.activeInferenceModel;
    if (active is InferenceModelSpec && active.fileType == spec.fileType) {
      return active;
    }
  }
  return spec;
}
