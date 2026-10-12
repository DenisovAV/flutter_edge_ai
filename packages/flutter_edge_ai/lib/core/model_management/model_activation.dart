import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/model_file_manager_interface.dart';

/// Internal contract used by core installers after all model files are ready.
///
/// This library is deliberately not exported from `flutter_edge_ai.dart`.
abstract interface class InstalledModelActivation {
  Future<void> activateInstalledModel(ModelSpec spec);
}

Future<void> activateInstalledModel(
  ModelFileManager manager,
  ModelSpec spec,
) async {
  if (manager case final InstalledModelActivation activation) {
    await activation.activateInstalledModel(spec);
    return;
  }

  // A custom platform manager may not implement core's internal capability.
  // Its existing public readiness contract remains the compatible fallback.
  await manager.ensureModelReadyFromSpec(spec);
}
