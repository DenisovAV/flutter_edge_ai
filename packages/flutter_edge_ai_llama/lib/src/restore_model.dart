import 'package:flutter_edge_ai/core/model_management/active_identity_store.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/model_activation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:shared_preferences/shared_preferences.dart';

/// Restores an installed GGUF identity after Flutter Edge AI initialization.
///
/// Core 2.2.0's native restart path checks a managed write target even for an
/// imported file. This fallback restores the persisted source through core's
/// normal installed-file validation. It never downloads or selects a different
/// model. Returns false for absent, unrelated, malformed or missing models.
/// Core does not persist inference LoRA companions; apps must reinstall that
/// spec or pass the adapter explicitly when creating a session after restart.
Future<bool> restoreInstalledLlamaModel() async {
  final manager = edge.FlutterEdgeAiPlugin.instance.modelManager;
  await manager.ensureInitialized();
  if (manager.activeInferenceModel != null) return false;
  final prefs = await SharedPreferences.getInstance();
  final record = ActiveIdentityStore.read(prefs, ActiveIdentityKind.inference);
  final filename = record?[PreferencesKeys.activeInferenceFilename];
  if (record?[PreferencesKeys.activeInferenceFileType] !=
          edge.ModelFileType.binary.name ||
      filename == null ||
      !filename.toLowerCase().endsWith('.gguf')) {
    return false;
  }
  final source = edge.ModelSource.tryDecode(
    record?[PreferencesKeys.activeInferenceSource],
  );
  final typeName = record?[PreferencesKeys.activeInferenceModelType];
  final type = edge.ModelType.values
      .where((type) => type.name == typeName)
      .firstOrNull;
  if (source == null || type == null) return false;
  final spec = edge.InferenceModelSpec(
    name: filename,
    modelSource: source,
    modelType: type,
    fileType: edge.ModelFileType.binary,
  );
  if (spec.files.first.filename != filename ||
      !await manager.isModelInstalled(spec)) {
    return false;
  }
  await activateInstalledModel(manager, spec);
  return true;
}
