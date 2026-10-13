/// One rule for installing a model's files, used by the installers — the
/// inference, STT, embedding and TTS builders, and `ensureModelReadyFromSpec`
/// with the legacy calls that go through it on Android, iOS and desktop — so
/// a name installed again from another source behaves the same way. The web
/// model manager and the legacy `downloadModel` calls do not follow it yet.
///
/// Each file of a spec has a repository record that says whose the file is
/// and where it lives. A file is skipped only when its record already names
/// the requested source and the file is there as it was written; otherwise
/// it is installed from the requested source. A URL is compared without its
/// query, fragment and credentials, so a refreshed signed link is the same
/// source — and a version told apart only by the query is not. These
/// installers never write over a file the app installed with `fromFile` nor
/// delete one, and delete core's own earlier copy of a name once the new
/// file is active, or at the next start, and only when no record reads it.
///
/// An installer [planInstall]s the spec's files — an error is raised there,
/// before anything changes —, [installPlanned]s the result, activates the
/// spec and then [CopyRelease.run]s. A copy an interrupted install leaves
/// behind is released at the next start ([releasePendingCopies]).
///
/// Internal to core; not exported from `flutter_edge_ai.dart`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/src/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/model_management/utils/local_file.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/model_file_manager_interface.dart';

/// What installing one file of a spec does, as [planInstall] decided it.
@immutable
final class FileInstallStep {
  const FileInstallStep._(
    this.file, {
    required this.installs,
    this.replacedCopy,
  });

  /// The file: the name it is recorded under and the requested source.
  final ModelFile file;

  /// False when the file is installed from this source already: skipped.
  final bool installs;

  /// Core's earlier copy of this name, released once the spec is active.
  final String? replacedCopy;
}

/// Decides, for each of [files], whether it is installed and which earlier
/// copy of core's it replaces — reading records and files, changing nothing.
///
/// Throws a [ModelStorageException] before anything is installed when a file
/// the app passed with `fromFile` is not there (naming every such file), when
/// a copy core would make lands on a file the app installed with `fromFile` —
/// installing it would overwrite the app's file —, or when no handler
/// installs a file's source.
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
  final appFiles = <_AppFile>[
    if (!kIsWeb)
      for (final info in await repository.listInstalled())
        if (info.source case FileSource(path: final recorded))
          (name: info.id, location: await appFileLocationNow(recorded)),
  ];

  final steps = [
    for (final file in files)
      await _plan(file, await repository.loadModel(file.filename), appFiles),
  ];
  for (final step in steps) {
    if (step.installs &&
        registry.sourceHandlerRegistry.getHandler(step.file.source) == null) {
      throw ModelStorageException(
        'No source handler for ${step.file.source.runtimeType} '
            '("${step.file.filename}")',
        null,
        'install',
      );
    }
  }
  return steps;
}

typedef _AppFile = ({String name, String location});

Future<FileInstallStep> _plan(
  ModelFile file,
  repo.ModelInfo? record,
  List<_AppFile> appFiles,
) async {
  FileInstallStep install({String? replacing}) =>
      FileInstallStep._(file, installs: true, replacedCopy: replacing);
  final skip = FileInstallStep._(file, installs: false);
  final requested = file.source;

  if (requested is FileSource) {
    if (record == null) return install();
    final recorded = record.source;
    // The app's file at the recorded path; picked from anywhere else, the
    // record follows the pick.
    if (recorded is FileSource) {
      return requested.path == recorded.path ? skip : install();
    }
    // The file the record reads — core's copy, or a resource of the iOS
    // bundle — handed back (a restored spec carries its path, and so does
    // getModelPath) is the same install and stays core's, unless the app has
    // written a file of its own there since.
    final location = await _readLocation(record);
    final identity = location == null
        ? FileIdentity.different
        : await compareFiles(location, requested.path);
    if (identity == FileIdentity.same &&
        await _hasRecordedSize(record, requested.path)) {
      return skip;
    }
    // Core's copy goes only when it is known to be another file.
    return install(
      replacing: identity == FileIdentity.different
          ? await _coreCopy(record)
          : null,
    );
  }

  if (record != null &&
      record.source is! FileSource &&
      _sameSource(requested, record.source) &&
      await _isThere(record)) {
    return skip;
  }
  final target = await _copyTarget(file.filename, requested);
  if (target != null) {
    for (final app in appFiles) {
      final identity = await compareFiles(app.location, target);
      if (identity == FileIdentity.different) continue;
      throw ModelStorageException(
        identity == FileIdentity.same
            ? '${file.filename} would be written to $target, which is '
                  '${app.name}, a file the app installed with fromFile. '
                  'Install it with fromFile, or move it out of the model '
                  'directory first.'
            : '${file.filename} would be written to $target, and whether '
                  'that is ${app.name}, a file the app installed with '
                  'fromFile, could not be found out. Nothing was installed.',
        null,
        'install',
      );
    }
  }
  // Nothing recorded, or the app's own file: the copy takes over the name.
  if (record == null || record.source is FileSource) return install();
  final copy = await _coreCopy(record);
  final replaced =
      copy != null &&
      (target == null ||
          await compareFiles(target, copy) == FileIdentity.different);
  return install(replacing: replaced ? copy : null);
}

/// Whether the file at [filePath] still has the size [record] was written
/// with — what tells core's copy from a file of the app's written over it,
/// or from a copy cut short.
Future<bool> _hasRecordedSize(repo.ModelInfo record, String filePath) async {
  final stamp = await fileStamp(filePath);
  return stamp == null ||
      record.sizeBytes <= 0 ||
      stamp.size == record.sizeBytes;
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

/// Whether the file [record] describes is where it says, as it was written.
Future<bool> _isThere(repo.ModelInfo record) async {
  if (kIsWeb) return true;
  final location = await _readLocation(record);
  return location != null &&
      await ServiceRegistry.instance.fileSystemService.fileExists(location) &&
      await _hasRecordedSize(record, location);
}

/// Where [record]'s file is read from in this run, or null when that cannot
/// be found out (an iOS bundle resource that is gone).
Future<String?> _readLocation(repo.ModelInfo record) =>
    _locate(record, inBundle: _bundlePath);

/// Where [record]'s file is read from in this run, as the engines read it,
/// and what `FlutterEdgeAi.getModelPath` returns for a name with a record:
/// the app's file where it is now (on iOS in the app's current container), a
/// resource of the iOS bundle in place, otherwise core's copy.
///
/// Throws what the bundle lookup throws for a resource the iOS app bundle
/// does not hold, as loading the model does. Native only: on web a model
/// core holds is not a file, and this throws [UnsupportedError] for one.
Future<String> recordedFileLocation(repo.ModelInfo record) async {
  final location = await _locate(
    record,
    inBundle: ServiceRegistry.instance.fileSystemService.getBundledResourcePath,
  );
  if (location == null) {
    // Core names no copy of its own only on web.
    throw UnsupportedError('${record.id} is not a file on this platform');
  }
  return location;
}

/// The one answer to where [record]'s file is; [inBundle] finds a resource
/// of the iOS bundle.
Future<String?> _locate(
  repo.ModelInfo record, {
  required Future<String?> Function(String resourceName) inBundle,
}) async {
  return switch (record.source) {
    FileSource(:final path) => await appFileLocationNow(path),
    BundledSource(:final resourceName) when !bundledResourcesAreCopies =>
      await inBundle(resourceName),
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
/// core holds under a name takes it over: whatever the app registered under
/// that name is forgotten.
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
      await _forgetAppRegistration(file);
      onFileDone?.call(i);
      continue;
    }
    if (!installing) {
      installing = true;
      await beforeInstalling?.call();
    }
    if (step.replacedCopy case final copy?) {
      await _journal(file.filename, copy);
    }

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
    await _forgetAppRegistration(file);
    onFileDone?.call(i);
  }
  return const CopyRelease._();
}

/// A file core holds under its name — a copy, or a bundle resource — is not
/// the app's: whatever the app registered under that name (an install of
/// its own, or one that releases up to 2.2.0 never unregistered) is
/// forgotten.
Future<void> _forgetAppRegistration(ModelFile file) async {
  if (file.source is FileSource) return;
  final registry = ServiceRegistry.instance.protectedFilesRegistry;
  await registry.unprotect(file.filename);
  await registry.unregisterExternalPath(file.filename);
}

/// Releases the earlier copies an install replaced, once its spec is active.
final class CopyRelease {
  const CopyRelease._();

  /// Releases the journaled copies of [activated]'s files — this install's,
  /// and those an earlier attempt left — now that it is the active spec.
  ///
  /// Never throws. A copy that cannot be deleted yet (Windows keeps a loaded
  /// model's file open), one a record still reads, and one another active
  /// model lists stay journaled for a later release or the next start.
  Future<void> run(
    ModelFileManager manager,
    ModelSpec activated,
  ) => _inJournalLane(
    () => _releaseJournaled(
      names: {for (final file in activated.files) file.filename},
      stillActive: [
        if (activated.type != ModelManagementType.inference)
          manager.activeInferenceModel,
        if (activated.type != ModelManagementType.embedding)
          manager.activeEmbeddingModel,
        if (activated.type != ModelManagementType.stt) manager.activeSttModel,
        if (activated.type != ModelManagementType.tts) manager.activeTtsModel,
      ].nonNulls.toList(),
    ),
  );
}

/// Releases every copy the journal still holds: what an install could not
/// delete, or did not get to before the app stopped. Runs at start, before
/// any model is restored. Never throws.
Future<void> releasePendingCopies() => _inJournalLane(_releaseJournaled);

/// The journal is read, worked on and written back by one operation at a
/// time: a release that took a while would otherwise write back a journal
/// without the copy an install recorded meanwhile, and lose it.
Future<void> _journalLane = Future<void>.value();

Future<T> _inJournalLane<T>(Future<T> Function() operation) {
  final done = _journalLane.then((_) => operation());
  _journalLane = done.then<void>((_) {}, onError: (Object _) {});
  return done;
}

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
    final storage = await registry.fileSystemService.getModelStorageDirectory();
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
      final file = path.join(storage, copy.path);
      switch (await _verdict(copy, file, storage, read)) {
        case _Verdict.keep:
          kept.add(copy);
        case _Verdict.forget:
          break;
        case _Verdict.delete:
          try {
            await registry.fileSystemService.deleteFile(file);
            edgeAiLog('[Install] released ${copy.name}: deleted $file');
          } on Exception catch (e) {
            edgeAiLog('[Install] cannot delete $file yet ($e)');
            kept.add(copy);
          }
      }
    }
    await _writeJournal(prefs, kept);
  } catch (e, stackTrace) {
    edgeAiLog('[Install] releasing replaced copies failed: $e\n$stackTrace');
  }
}

/// What becomes of a journaled copy.
enum _Verdict {
  /// Free: core's copy, unchanged, read by no record.
  delete,

  /// Read by a record now, or not to be told apart from one: later.
  keep,

  /// Not that copy any more — gone, or written since — or not core's.
  forget,
}

Future<_Verdict> _verdict(
  _PendingCopy copy,
  String file,
  String storage,
  List<String> read,
) async {
  if (!path.isWithin(storage, file)) {
    edgeAiLog('[Install] $file is not in the model directory; kept');
    return _Verdict.forget;
  }
  final stamp = await fileStamp(file);
  if (stamp == null ||
      stamp.size != copy.size ||
      stamp.modifiedMs != copy.modifiedMs) {
    return _Verdict.forget;
  }
  for (final location in read) {
    if (await compareFiles(location, file) != FileIdentity.different) {
      edgeAiLog('[Install] $file is read by a record; kept for now');
      return _Verdict.keep;
    }
  }
  return _Verdict.delete;
}

/// A copy waiting to be released: its name, its path relative to the model
/// directory (which moves with the app's container on iOS), and the file it
/// was when journaled.
final class _PendingCopy {
  const _PendingCopy(this.name, this.path, this.size, this.modifiedMs);

  final String name;
  final String path;
  final int size;
  final int modifiedMs;

  static _PendingCopy? tryParse(Object? json) => switch (json) {
    {
      'name': final String name,
      'path': final String path,
      'size': final int size,
      'modifiedMs': final int modifiedMs,
    } =>
      _PendingCopy(name, path, size, modifiedMs),
    _ => null,
  };

  Map<String, Object> toJson() => {
    'name': name,
    'path': path,
    'size': size,
    'modifiedMs': modifiedMs,
  };
}

/// Records that [copyPath], core's copy of [name], is to be released.
Future<void> _journal(String name, String copyPath) => _inJournalLane(() async {
  if (kIsWeb) return;
  final storage = await ServiceRegistry.instance.fileSystemService
      .getModelStorageDirectory();
  // Only a copy in the model directory is ever released.
  if (!path.isWithin(storage, copyPath)) return;
  final stamp = await fileStamp(copyPath);
  if (stamp == null) return;
  final relative = path.relative(copyPath, from: storage);
  final prefs = await SharedPreferences.getInstance();
  final journal = _readJournal(prefs)
    ..removeWhere((copy) => copy.name == name && copy.path == relative)
    ..add(_PendingCopy(name, relative, stamp.size, stamp.modifiedMs));
  await _writeJournal(prefs, journal);
});

List<_PendingCopy> _readJournal(SharedPreferences prefs) {
  try {
    final raw = prefs.getString(PreferencesKeys.pendingCopyReleases);
    if (raw == null) return [];
    final entries = jsonDecode(raw);
    if (entries is! List) throw FormatException('not a list', raw);
    final journal = <_PendingCopy>[];
    for (final entry in entries) {
      if (_PendingCopy.tryParse(entry) case final copy?) {
        journal.add(copy);
      } else {
        edgeAiLog('[Install] unreadable copy journal entry dropped: $entry');
      }
    }
    return journal;
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
