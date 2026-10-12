/// One rule for installing a model's files, used by every installer — the
/// builders, `ensureModelReadyFromSpec` and the legacy calls that go through
/// it — so a name installed again from another source behaves the same way
/// everywhere.
///
/// Each file of a spec has a repository record that says whose the file is
/// and where it lives. A file is skipped only when its record already names
/// the requested source and the file is there; otherwise it is installed
/// from the requested source. Core never writes over or deletes a file the
/// app installed with `fromFile`, and deletes its own earlier copy of a name
/// only once the new file is active and no record reads that copy.
///
/// An installer [planInstall]s the spec's files — every error is raised
/// there, before anything changes —, [installPlanned]s the result, activates
/// the spec and then [CopyRelease.run]s. A copy an interrupted install leaves
/// behind is released at the next start ([releasePendingCopies]).
///
/// Internal to core; not exported from `flutter_edge_ai.dart`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/core/model_management/utils/local_file.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/model_file_manager_interface.dart';

/// What installing one file of a spec does, as [planInstall] decided it.
@immutable
final class FileInstallStep {
  const FileInstallStep._(this.file, {required this.installs, this.releases});

  /// The file: the name it is recorded under and the requested source.
  final ModelFile file;

  /// False when the file is installed from this source already: skipped.
  final bool installs;

  /// Core's earlier copy of this name, released once the spec is active.
  final String? releases;
}

/// Decides, for each of [files], whether it is installed and which earlier
/// copy of core's it replaces — reading records and files, changing nothing.
///
/// Throws a [ModelStorageException] before anything is installed when a file
/// the app passed with `fromFile` is not there (naming every such file), or
/// when a copy core would make lands on a file the app installed with
/// `fromFile` — installing it would overwrite the app's file.
Future<List<FileInstallStep>> planInstall(List<ModelFile> files) async {
  final registry = ServiceRegistry.instance;
  final repository = registry.modelRepository;

  if (!kIsWeb) {
    final missing = [
      for (final file in files)
        if (file.source case FileSource(path: final picked))
          if (!await registry.fileSystemService.fileExists(picked)) picked,
    ];
    if (missing.isNotEmpty) {
      throw ModelStorageException(
        'External file does not exist: ${missing.join(', ')}',
        null,
        'install',
      );
    }
  }

  // Where every file the app installed is, so no copy lands on one.
  final appFiles = <String>[
    if (!kIsWeb)
      for (final info in await repository.listInstalled())
        if (info.source case FileSource(path: final recorded))
          await appFileLocationNow(recorded),
  ];

  return [
    for (final file in files)
      await _plan(file, await repository.loadModel(file.filename), appFiles),
  ];
}

Future<FileInstallStep> _plan(
  ModelFile file,
  repo.ModelInfo? record,
  List<String> appFiles,
) async {
  FileInstallStep install({String? releasing}) =>
      FileInstallStep._(file, installs: true, releases: releasing);
  final skip = FileInstallStep._(file, installs: false);
  final requested = file.source;
  final recorded = record?.source;

  if (requested is FileSource) {
    if (record == null) return install();
    // The app's file at the recorded path; picked from anywhere else, the
    // record follows the pick.
    if (recorded is FileSource) {
      return requested.path == recorded.path ? skip : install();
    }
    final copy = await _coreCopy(record);
    // Core's own copy handed back — a restored spec carries its path, and so
    // does getModelPath: the same install, and the file stays core's.
    if (copy != null && await isSameFile(copy, requested.path)) return skip;
    return install(releasing: copy);
  }

  final target = await _copyTarget(file.filename, requested);
  if (target != null) {
    for (final appFile in appFiles) {
      if (await isSameFile(appFile, target)) {
        throw ModelStorageException(
          '${file.filename} would be written to $target, which is a file the '
              'app installed with fromFile. Install that file with fromFile, or '
              'move it out of the model directory first.',
          null,
          'install',
        );
      }
    }
  }
  // Nothing recorded, or the app's own file: the copy takes over the name.
  if (record == null || recorded is FileSource) return install();
  if (_sameSource(requested, recorded!) && await _isThere(record)) return skip;
  final copy = await _coreCopy(record);
  final replaced =
      copy != null && (target == null || !await isSameFile(target, copy));
  return install(releasing: replaced ? copy : null);
}

/// Where core's own copy of [record]'s file is, or null when the record is
/// not a copy core made: the app's file, a resource read in place from the
/// iOS bundle, or any model on web.
Future<String?> _coreCopy(repo.ModelInfo record) async {
  if (kIsWeb) return null;
  final fs = ServiceRegistry.instance.fileSystemService;
  return switch (record.source) {
    FileSource() => null,
    BundledSource(:final resourceName) =>
      bundledResourcesAreCopies
          ? await fs.getWriteTargetPath(resourceName)
          : null,
    _ => await fs.getReadTargetPath(record.id),
  };
}

/// Where core would write its copy of [requested] under [filename], or null
/// when it writes none: the app's file and a resource of the iOS bundle are
/// read in place, and a model on web is a URL.
Future<String?> _copyTarget(String filename, ModelSource requested) async {
  if (kIsWeb) return null;
  final fs = ServiceRegistry.instance.fileSystemService;
  return switch (requested) {
    FileSource() => null,
    BundledSource(:final resourceName) =>
      bundledResourcesAreCopies
          ? await fs.getWriteTargetPath(resourceName)
          : null,
    _ => await fs.getWriteTargetPath(filename),
  };
}

/// Whether the file [record] describes is where it says.
Future<bool> _isThere(repo.ModelInfo record) async {
  if (kIsWeb) return true;
  final location = await _readLocation(record);
  return location != null &&
      await ServiceRegistry.instance.fileSystemService.fileExists(location);
}

/// Where [record]'s file is read from in this run, or null when that cannot
/// be found out (an iOS bundle resource that is gone).
Future<String?> _readLocation(repo.ModelInfo record) async {
  return switch (record.source) {
    FileSource(:final path) => await appFileLocationNow(path),
    BundledSource(:final resourceName) when !bundledResourcesAreCopies =>
      await _bundlePath(resourceName),
    _ => await _coreCopy(record),
  };
}

Future<String?> _bundlePath(String resourceName) async {
  try {
    return await ServiceRegistry.instance.fileSystemService
        .getBundledResourcePath(resourceName);
  } on Exception {
    return null;
  }
}

/// Whether [a] and [b] fetch the same file: a URL without its query,
/// fragment and credentials — a refreshed signed link, or `?download=true`,
/// is the same model —, the same asset, the same bundled resource.
bool _sameSource(ModelSource a, ModelSource b) => switch ((a, b)) {
  (NetworkSource(url: final x), NetworkSource(url: final y)) =>
    _withoutQuery(x) == _withoutQuery(y),
  (
    AssetSource(normalizedPath: final x),
    AssetSource(normalizedPath: final y),
  ) =>
    x == y,
  (
    BundledSource(resourceName: final x),
    BundledSource(resourceName: final y),
  ) =>
    x == y,
  _ => false,
};

String _withoutQuery(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

/// Installs what [planInstall] decided, in order, and returns what releases
/// the earlier copies once the spec is active.
///
/// A copy to release is journaled before its record changes, so one an
/// interrupted install leaves is still released at the next start. A file
/// installed from anything but the app's file takes its name over: whatever
/// the app registered under that name is forgotten.
///
/// [progress] holds one callback per step (null: no progress for that one);
/// [beforeInstalling] runs once, before the first file that is installed,
/// and not at all when every file is skipped.
Future<CopyRelease> installPlanned(
  List<FileInstallStep> steps, {
  required repo.ModelType modelType,
  CancelToken? cancelToken,
  List<void Function(int percent)?> progress = const [],
  void Function(int index)? onFileDone,
  Future<void> Function()? beforeInstalling,
}) async {
  final registry = ServiceRegistry.instance;
  var installing = false;
  for (var i = 0; i < steps.length; i++) {
    cancelToken?.throwIfCancelled();
    final step = steps[i];
    final file = step.file;
    if (!step.installs) {
      edgeAiLog('ℹ️  Already installed: ${file.filename}');
      onFileDone?.call(i);
      continue;
    }
    if (!installing) {
      installing = true;
      await beforeInstalling?.call();
    }
    if (step.releases case final copy?) await _journal(file.filename, copy);

    final source = file.source;
    final handler = registry.sourceHandlerRegistry.getHandler(source);
    if (handler == null) {
      throw StateError(
        'No source handler for ${source.runtimeType} ("${file.filename}").',
      );
    }
    final onProgress = i < progress.length ? progress[i] : null;
    if (onProgress != null) {
      await for (final percent in handler.installWithProgress(
        source,
        cancelToken: cancelToken,
        targetFilename: file.filename,
        modelType: modelType,
      )) {
        onProgress(percent);
      }
    } else {
      await handler.install(
        source,
        cancelToken: cancelToken,
        targetFilename: file.filename,
        modelType: modelType,
      );
    }
    if (source is! FileSource) {
      await registry.protectedFilesRegistry.unprotect(file.filename);
      await registry.protectedFilesRegistry.unregisterExternalPath(
        file.filename,
      );
    }
    onFileDone?.call(i);
  }
  return const CopyRelease._();
}

/// Releases the earlier copies an install replaced, once its spec is active.
final class CopyRelease {
  const CopyRelease._();

  /// Releases the journaled copies of [activated]'s files — this install's,
  /// and those an earlier attempt left — now that it is the active spec.
  ///
  /// Never throws. A copy that cannot be deleted yet (Windows keeps a loaded
  /// model's file open) stays journaled for the next start; one another
  /// active model still lists waits for it too.
  Future<void> run(ModelFileManager manager, ModelSpec activated) =>
      _releaseJournaled(
        names: {for (final file in activated.files) file.filename},
        stillActive: [
          if (activated.type != ModelManagementType.inference)
            manager.activeInferenceModel,
          if (activated.type != ModelManagementType.embedding)
            manager.activeEmbeddingModel,
          if (activated.type != ModelManagementType.stt) manager.activeSttModel,
          if (activated.type != ModelManagementType.tts) manager.activeTtsModel,
        ].nonNulls.toList(),
      );
}

/// Releases every copy the journal still holds: what an install could not
/// delete, or did not get to before the app stopped. Runs at start, before
/// any model is restored. Never throws.
Future<void> releasePendingCopies() => _releaseJournaled();

Future<void> _releaseJournaled({
  Set<String>? names,
  List<ModelSpec> stillActive = const [],
}) async {
  if (kIsWeb) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final journal = _readJournal(prefs);
    if (journal.isEmpty) return;
    final registry = ServiceRegistry.instance;
    final fs = registry.fileSystemService;
    final storage = await fs.getModelStorageDirectory();
    final inUse = {
      for (final spec in stillActive)
        for (final file in spec.files) file.filename,
    };
    // Where every record — of every name — reads its file.
    final read = [
      for (final info in await registry.modelRepository.listInstalled())
        ?await _readLocation(info),
    ];

    final kept = <_PendingCopy>[];
    for (final copy in journal) {
      if ((names != null && !names.contains(copy.name)) ||
          inUse.contains(copy.name)) {
        kept.add(copy);
        continue;
      }
      if (!await _mayDelete(copy, storage, read)) {
        edgeAiLog('[Install] kept ${copy.path}: it is not a free copy');
        continue;
      }
      try {
        await fs.deleteFile(copy.path);
        edgeAiLog('[Install] released ${copy.name}: deleted ${copy.path}');
      } on Exception catch (e) {
        edgeAiLog('[Install] cannot delete ${copy.path} yet ($e)');
        kept.add(copy);
      }
    }
    await _writeJournal(prefs, kept);
  } catch (e, stackTrace) {
    edgeAiLog('[Install] releasing replaced copies failed: $e\n$stackTrace');
  }
}

/// A journaled copy is deleted only if it is in core's model directory —
/// never one a desktop install before 0.15.1 left in the user's Documents —,
/// is still the file that was journaled, and no record reads it.
Future<bool> _mayDelete(
  _PendingCopy copy,
  String storage,
  List<String> read,
) async {
  if (!path.isWithin(storage, copy.path)) return false;
  final stamp = await fileStamp(copy.path);
  if (stamp == null ||
      stamp.size != copy.size ||
      stamp.modifiedMs != copy.modifiedMs) {
    return false;
  }
  for (final location in read) {
    if (await isSameFile(location, copy.path)) return false;
  }
  return true;
}

/// A copy waiting to be released: its name, its path, and the file it was
/// when journaled.
final class _PendingCopy {
  const _PendingCopy(this.name, this.path, this.size, this.modifiedMs);

  factory _PendingCopy.fromJson(Map<String, Object?> json) => _PendingCopy(
    json['name']! as String,
    json['path']! as String,
    json['size']! as int,
    json['modifiedMs']! as int,
  );

  final String name;
  final String path;
  final int size;
  final int modifiedMs;

  Map<String, Object> toJson() => {
    'name': name,
    'path': path,
    'size': size,
    'modifiedMs': modifiedMs,
  };
}

Future<void> _journal(String name, String copyPath) async {
  if (kIsWeb) return;
  final stamp = await fileStamp(copyPath);
  if (stamp == null) return;
  final prefs = await SharedPreferences.getInstance();
  final journal = _readJournal(prefs)
    ..removeWhere((copy) => copy.name == name && copy.path == copyPath)
    ..add(_PendingCopy(name, copyPath, stamp.size, stamp.modifiedMs));
  await _writeJournal(prefs, journal);
}

List<_PendingCopy> _readJournal(SharedPreferences prefs) {
  final raw = prefs.getString(PreferencesKeys.pendingCopyReleases);
  if (raw == null) return [];
  try {
    return [
      for (final entry in jsonDecode(raw) as List)
        _PendingCopy.fromJson(entry as Map<String, Object?>),
    ];
  } on Object catch (e) {
    edgeAiLog('[Install] unreadable copy journal dropped: $e');
    return [];
  }
}

Future<void> _writeJournal(
  SharedPreferences prefs,
  List<_PendingCopy> journal,
) async {
  if (journal.isEmpty) {
    await prefs.remove(PreferencesKeys.pendingCopyReleases);
  } else {
    await prefs.setString(
      PreferencesKeys.pendingCopyReleases,
      jsonEncode([for (final copy in journal) copy.toJson()]),
    );
  }
}
