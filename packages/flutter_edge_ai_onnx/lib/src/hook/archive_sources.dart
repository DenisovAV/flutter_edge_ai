// Where the build hook downloads a pinned archive from: an ordered list of
// sources for the same bytes. github.com/microsoft/onnxruntime and
// onnxruntime-genai have returned 404 since 2026-11-17, so an archive lists
// Microsoft's release URL first and this repository's mirror release after
// it. A source that cannot serve the file is skipped; a source that serves
// different bytes is an error, never a reason to try the next one.
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Downloads [url] into [dest]. Returns false when the source cannot serve
/// the file (an HTTP status other than 200, or a network error), after
/// saying why through [log]; [dest] is then left absent.
typedef ArchiveFetch =
    Future<bool> Function(Uri url, File dest, void Function(String) log);

/// The outcome of [fetchPinnedArchive].
final class PinnedArchiveResult {
  const PinnedArchiveResult._(this.source, this.error);

  /// The source whose bytes matched the pin, or null on failure.
  final Uri? source;

  /// Why no source could be used, or null on success.
  final String? error;

  bool get ok => source != null;
}

/// Fetches the archive pinned to [sha256Hex] into [dest] from the first of
/// [sources] that serves it.
///
/// A source that cannot serve the file is skipped. A source that serves bytes
/// whose SHA-256 differs from [sha256Hex] ends the attempt with an error and
/// [dest] deleted: every source is meant to hold the same bytes, so a mismatch
/// is a broken or tampered source, not a reason to look further.
Future<PinnedArchiveResult> fetchPinnedArchive({
  required List<Uri> sources,
  required String sha256Hex,
  required File dest,
  required ArchiveFetch fetch,
  required void Function(String) log,
}) async {
  if (sources.isEmpty) {
    return const PinnedArchiveResult._(null, 'no source is listed');
  }
  final tried = <String>[];
  for (final source in sources) {
    if (dest.existsSync()) dest.deleteSync();
    log('downloading $source ...');
    final served = await fetch(source, dest, log);
    if (!served || !dest.existsSync()) {
      tried.add('$source');
      continue;
    }
    final actual = sha256.convert(await dest.readAsBytes()).toString();
    if (actual != sha256Hex) {
      dest.deleteSync();
      return PinnedArchiveResult._(
        null,
        'CHECKSUM MISMATCH for $source\n'
        '  expected: $sha256Hex\n'
        '  actual:   $actual',
      );
    }
    log('checksum verified ($source)');
    return PinnedArchiveResult._(source, null);
  }
  return PinnedArchiveResult._(
    null,
    'not available from any source: ${tried.join(', ')}',
  );
}
