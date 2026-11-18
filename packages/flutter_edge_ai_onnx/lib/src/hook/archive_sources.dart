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
/// saying why through [log]; [dest] is then left absent. Any other failure
/// (the local disk, a permission) is thrown, not reported as an unavailable
/// source.
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
    _deleteQuietly(dest);
    log('downloading $source ...');
    final served = await fetch(source, dest, log);
    if (!served) {
      tried.add('$source');
      continue;
    }
    if (!dest.existsSync()) {
      log('$source reported a download but left no file');
      tried.add('$source');
      continue;
    }
    final size = dest.lengthSync();
    final actual = (await sha256.bind(dest.openRead()).first).toString();
    if (actual != sha256Hex) {
      dest.deleteSync();
      return PinnedArchiveResult._(
        null,
        'CHECKSUM MISMATCH for $source ($size bytes)\n'
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

/// The [ArchiveFetch] the hook uses: an HTTP GET, redirects followed (GitHub
/// release assets redirect to signed storage URLs).
///
/// A status other than 200 and a network failure (socket, TLS, HTTP
/// protocol) mean the source cannot serve the file. Anything else, a local
/// write failing for one, is thrown: trying the next source would only repeat
/// it and then blame the network.
Future<bool> httpArchiveFetch(
  Uri url,
  File dest,
  void Function(String) log,
) async {
  final client = HttpClient();
  try {
    final HttpClientResponse response;
    try {
      final request = await client.getUrl(url);
      request.followRedirects = true;
      response = await request.close();
    } on Exception catch (e) {
      if (!_isNetworkError(e)) rethrow;
      log('download failed for $url: $e');
      return false;
    }
    if (response.statusCode != 200) {
      log('download failed (HTTP ${response.statusCode}) for $url');
      await response.drain<void>();
      return false;
    }
    final sink = dest.openWrite();
    try {
      await sink.addStream(response);
    } on Exception catch (e) {
      // Close before deleting: an open handle keeps Windows from deleting
      // the partial file, and the next source writes to the same path.
      try {
        await sink.close();
      } on Exception {
        // The write side failed too; the delete below still runs.
      }
      if (!_isNetworkError(e)) rethrow;
      log('download interrupted for $url: $e');
      _deleteQuietly(dest);
      return false;
    }
    await sink.close();
    return true;
  } finally {
    client.close();
  }
}

/// A failure of the source or the network, as opposed to the local machine.
bool _isNetworkError(Object e) =>
    e is SocketException || e is HttpException || e is TlsException;

/// Deletes a partial or rejected download without failing: a file still held
/// open (Windows) is truncated by the next source's `openWrite` anyway.
void _deleteQuietly(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Left for the next attempt to replace.
  }
}
