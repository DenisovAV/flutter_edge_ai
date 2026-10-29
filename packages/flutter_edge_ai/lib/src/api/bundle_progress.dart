import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/src/model_management/install_rule.dart';
import 'package:flutter_edge_ai/src/services/file_system_service.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:meta/meta.dart' show visibleForTesting;

/// Sizes a caller already knows for a bundle's files, in bytes by each
/// file's `prefsKey` (its plain manifest name), keyed by the installation
/// builder. A file found here is never asked of the network. Internal.
final knownBundleFileSizes = Expando<Map<String, int>>('knownBundleFileSizes');

/// The size of each of [steps]' files before the install, in order; null
/// where it cannot be known before the copy.
///
/// - [known] (by `prefsKey`) first;
/// - a file installed already, or one the app passes with `fromFile`: its
///   length on disk;
/// - a network file: one HEAD request each, all at once, with the download's
///   token (`RemoteSizeProbe`);
/// - an asset or bundled file: null.
///
/// Throws [DownloadCancelledException] when [cancelToken] is cancelled while
/// the requests run; nothing is installed by then.
Future<List<int?>> bundleFileSizes(
  List<FileInstallStep> steps, {
  Map<String, int>? known,
  CancelToken? cancelToken,
}) async {
  final registry = ServiceRegistry.instance;
  final fileSystem = registry.fileSystemService;

  Future<int?> diskSize(String path) => sizeOnDisk(fileSystem, path);

  Future<int?> sizeOf(FileInstallStep step) async {
    final file = step.file;
    if (known?[file.prefsKey] case final bytes?) return bytes;
    final source = file.source;
    if (source is FileSource) return diskSize(source.path);
    if (!step.installs) {
      return diskSize(await fileSystem.getReadTargetPath(file.filename));
    }
    if (source is NetworkSource) {
      final huggingFace = Uri.tryParse(
        source.url,
      )?.host.contains('huggingface.co');
      return registry.remoteSizeProbe.sizeOf(
        source.url,
        cancelToken: cancelToken,
        token:
            source.authToken ??
            (huggingFace == true ? registry.huggingFaceToken : null),
      );
    }
    return null;
  }

  cancelToken?.throwIfCancelled();
  final all = Future.wait([for (final step in steps) sizeOf(step)]);
  if (cancelToken != null) {
    await Future.any([all, cancelToken.whenCancelled]);
    cancelToken.throwIfCancelled();
  }
  return all;
}

/// The length of the file at [path], or null when it is not there or cannot
/// be read: a missing file is an unknown size, never 0.
@visibleForTesting
Future<int?> sizeOnDisk(FileSystemService fileSystem, String path) async {
  try {
    if (!await fileSystem.fileExists(path)) return null;
    return await fileSystem.getFileSize(path);
  } on Object {
    return null;
  }
}

/// One 0-100 progress for a bundle, from each file's own percent, weighted by
/// the file's bytes. When a size is unknown every file weighs the same (said
/// once in the debug log); within a file the percent stays continuous either
/// way. Reports only rising values, at most 99 while files install: 100 only
/// from [complete], once the install has succeeded.
final class BundleProgress {
  /// Progress for files of [sizes] (null = unknown), reported to [onProgress].
  BundleProgress(this._onProgress, List<int?> sizes, {String? bundle})
    : _weights = _weightsOf(sizes, bundle),
      _done = List.filled(sizes.length, 0.0);

  final void Function(int percent) _onProgress;
  final List<double> _weights;
  final List<double> _done;
  int _last = -1;

  static List<double> _weightsOf(List<int?> sizes, String? bundle) {
    final total = sizes.fold<int>(0, (sum, s) => sum + (s ?? 0));
    if (sizes.isEmpty) return const [];
    if (sizes.any((s) => s == null) || total == 0) {
      edgeAiLog(
        'ℹ️  ${bundle ?? 'Bundle'} progress: the size of '
        '${sizes.where((s) => s == null).length} of ${sizes.length} files is '
        'not known before the download, so each file counts the same.',
      );
      return List.filled(sizes.length, 1.0);
    }
    return [for (final s in sizes) s!.toDouble()];
  }

  /// Files [indices] are complete already: one report for all of them.
  void installedAlready(Iterable<int> indices) {
    if (indices.isEmpty) return;
    for (final i in indices) {
      _done[i] = _weights[i];
    }
    _emit();
  }

  /// File [index] is at [percent] (0-100) of its own bytes.
  void report(int index, int percent) {
    _done[index] = _weights[index] * percent.clamp(0, 100) / 100;
    _emit();
  }

  void _emit() {
    final total = _weights.fold<double>(0, (sum, w) => sum + w);
    if (total == 0) return;
    final done = _done.fold<double>(0, (sum, d) => sum + d);
    // 100 is said by complete() alone: the bundle still has to be activated.
    final overall = (done * 100 / total).floor().clamp(0, 99);
    if (overall > _last) {
      _last = overall;
      _onProgress(overall);
    }
  }

  /// The install succeeded: report 100 if it has not been yet.
  void complete() {
    if (_last < 100) {
      _last = 100;
      _onProgress(100);
    }
  }
}
