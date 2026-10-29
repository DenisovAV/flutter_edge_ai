import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/src/services/remote_size_probe.dart';
import 'package:meta/meta.dart' show visibleForTesting;

/// [RemoteSizeProbe] over `dart:io`'s [HttpClient] (Android, iOS, desktop).
///
/// Follows up to five redirects itself, so that the token goes to the
/// origin only, and reads the size from the final 200 answer.
final class HttpRemoteSizeProbe implements RemoteSizeProbe {
  /// A probe; [timeout] bounds each request and the read of its answer.
  HttpRemoteSizeProbe({this.timeout = const Duration(seconds: 15)});

  /// The limit of one HEAD request.
  final Duration timeout;

  /// Whether [b] is the origin of [a]: the same scheme, host and port. Only
  /// then does a request to [b] carry the token meant for [a].
  @visibleForTesting
  static bool sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  @override
  Future<int?> sizeOf(
    String url, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    // A cancel ends the requests at once instead of at their timeouts.
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancelled.then((_) => client.close(force: true)),
      );
    }
    try {
      final origin = Uri.parse(url);
      var uri = origin;
      for (var hop = 0; hop < 5; hop++) {
        if (cancelToken?.isCancelled ?? false) return null;
        final request = await client.headUrl(uri).timeout(timeout);
        request.followRedirects = false;
        // HttpClient asks for gzip by default, and a server that compresses
        // its answer (Hugging Face does for small files) then names no
        // Content-Length: ask for the bytes as they are.
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (token != null && token.isNotEmpty && sameOrigin(origin, uri)) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final response = await request.close().timeout(timeout);
        await response.drain<void>().timeout(timeout);
        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) return null;
          uri = uri.resolve(location);
          continue;
        }
        if (status != HttpStatus.ok) return null;
        // Hugging Face names the file's size on its own answers as
        // X-Linked-Size; elsewhere the Content-Length is the file.
        final linked = int.tryParse(
          response.headers.value('x-linked-size') ?? '',
        );
        if (linked != null && linked >= 0) return linked;
        final length = response.contentLength;
        return length >= 0 ? length : null;
      }
      return null;
    } on Object {
      // A size is only for progress: the download itself reports its own
      // failure.
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
