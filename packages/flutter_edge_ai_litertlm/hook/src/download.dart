// A checksum-verified download for build hooks.
//
// The hook process gets HTTP(S)_PROXY / NO_PROXY from the hooks runner, and
// Dart's HttpClient already honours them and follows redirects by default.
// What it does not do on its own is give up: without timeouts a stalled
// transfer or a black-holing proxy hangs `flutter build` forever. So this adds
// connect and idle timeouts, retries with backoff for transient failures, and
// hashes while streaming to disk.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// [url] with any `user:password@` removed, for log and error text — a mirror
/// URL in a pubspec may carry credentials.
Uri redactUserInfo(Uri url) =>
    url.userInfo.isEmpty ? url : url.replace(userInfo: '');

/// [text] with [url]'s credentials masked. Errors from `dart:io` carry the
/// full request URI — an [HttpException] prints `uri = https://user:token@…` —
/// so error text built from them is scrubbed, not only what this code writes.
String redactUserInfoIn(String text, Uri url) {
  final info = url.userInfo;
  if (info.isEmpty) return text;
  // Only where a URL carries it, before the `@`: a short user name masked
  // everywhere would mangle the rest of the message.
  return text
      .replaceAll('$info@', '***@')
      .replaceAll('${Uri.decodeComponent(info)}@', '***@');
}

/// Downloads [url] to [dest] and verifies its SHA256 against [sha256Hex].
///
/// Writes to a sibling temp file and renames on success, so [dest] is either
/// absent or complete. Retries up to [attempts] times on network errors, 429
/// and 5xx; a 4xx other than 429 and a checksum mismatch fail at once.
Future<void> downloadVerified(
  Uri url,
  File dest,
  String sha256Hex, {
  int attempts = 3,
  Duration connectTimeout = const Duration(seconds: 30),
  Duration idleTimeout = const Duration(seconds: 60),
  Duration backoff = const Duration(seconds: 2),
}) async {
  final shown = redactUserInfo(url);
  Object? lastError;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    final part = File('${dest.path}.part-$pid');
    try {
      final request = await client.getUrl(url).timeout(connectTimeout);
      final response = await request.close().timeout(connectTimeout);
      final status = response.statusCode;
      if (status != 200) {
        await response.drain<void>().catchError((_) {});
        final transient = status == 429 || status >= 500;
        final error = HttpException('HTTP $status for $shown');
        if (!transient) throw _Fatal(error);
        throw error;
      }
      final digestSink = _DigestSink();
      final hasher = sha256.startChunkedConversion(digestSink);
      final out = part.openWrite();
      try {
        await for (final chunk in response.timeout(
          idleTimeout,
          onTimeout: (sink) => sink.addError(
            TimeoutException(
              'no data for ${idleTimeout.inSeconds}s from $shown',
            ),
          ),
        )) {
          hasher.add(chunk);
          out.add(chunk);
        }
        await out.flush();
      } finally {
        await out.close();
      }
      hasher.close();
      final actual = digestSink.value.toString();
      if (actual != sha256Hex) {
        throw _Fatal(
          StateError(
            'checksum mismatch for $shown: expected $sha256Hex, got $actual '
            '(a mirror serving different bytes, or a proxy rewriting them)',
          ),
        );
      }
      part.renameSync(dest.path);
      return;
    } on _Fatal catch (f) {
      // Built from [shown] here, so already free of credentials.
      throw f.error;
    } on Object catch (e) {
      lastError = e;
      if (attempt < attempts) {
        await Future<void>.delayed(backoff * attempt);
      }
    } finally {
      client.close(force: true);
      if (part.existsSync()) {
        try {
          part.deleteSync();
        } on FileSystemException {
          // Best effort; a later run uses a different pid suffix anyway.
        }
      }
    }
  }
  throw StateError(
    'could not download $shown after $attempts attempts: '
    '${redactUserInfoIn('$lastError', url)}. '
    'Behind a proxy, set HTTPS_PROXY for the build; offline, point the '
    'build at a local copy instead.',
  );
}

class _Fatal {
  _Fatal(this.error);
  final Object error;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
