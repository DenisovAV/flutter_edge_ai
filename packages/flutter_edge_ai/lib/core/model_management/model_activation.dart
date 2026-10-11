import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart';
import 'package:flutter_edge_ai/model_file_manager_interface.dart';
import 'package:path/path.dart' as path;

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

/// Whether a file whose repository record is [record] is installed from
/// [requested], so an installer can skip it.
///
/// A file the app picks with `fromFile` is installed from that path only.
/// Picked from a new path under a name already installed, its record has to
/// follow — the record is what a restart restores and what an uninstall
/// consults; picked again after the file is gone, the install reports that.
/// Any other request is installed whenever its name is.
Future<bool> isInstalledFrom(ModelInfo? record, ModelSource requested) async {
  if (record == null) return false;
  if (requested is! FileSource) return true;
  if (record.source.encode() != requested.encode()) return false;
  // On web a file is a URL registered for the session, so there is nothing
  // on disk to look for.
  return kIsWeb ||
      await ServiceRegistry.instance.fileSystemService.fileExists(
        requested.path,
      );
}

/// After [filename] was installed from [requested] in place of [replaced]: a
/// copy core made of it earlier — a download, an asset or Android bundled
/// copy — is dead weight once the file is read from where the app keeps it,
/// and nothing else would ever delete it, so it is deleted here, unless the
/// app's file is that copy.
Future<void> deleteReplacedCopy(
  String filename,
  ModelInfo? replaced,
  ModelSource requested,
) async {
  if (kIsWeb ||
      replaced == null ||
      replaced.source is FileSource ||
      requested is! FileSource) {
    return;
  }
  final fs = ServiceRegistry.instance.fileSystemService;
  final copy = await fs.getWriteTargetPath(filename);
  if (!path.equals(copy, requested.path) && await fs.fileExists(copy)) {
    await fs.deleteFile(copy);
  }
}
