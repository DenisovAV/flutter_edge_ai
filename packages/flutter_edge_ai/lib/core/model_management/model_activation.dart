import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart';
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

/// Whether [filename] is installed from [requested], so an installer can skip
/// it. A file the app picks with `fromFile` from a new path, under a name that
/// is already installed, is not: its record has to follow the new path, since
/// the record is what a restart restores and what an uninstall consults.
Future<bool> isInstalledFrom(
  ModelRepository repository,
  String filename,
  ModelSource requested,
) async {
  final record = await repository.loadModel(filename);
  if (record == null) return false;
  return requested is! FileSource ||
      record.source.encode() == requested.encode();
}
