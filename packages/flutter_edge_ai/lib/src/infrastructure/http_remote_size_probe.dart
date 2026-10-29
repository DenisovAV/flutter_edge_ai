import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/src/services/remote_size_probe.dart';

/// [RemoteSizeProbe] over `dart:io`'s [HttpClient] (Android, iOS, desktop).
///
/// Follows up to five redirects itself, so that it can read `X-Linked-Size`
/// on the redirect that carries it, and stops at the first answer that names
/// a size.
final class HttpRemoteSizeProbe implements RemoteSizeProbe {
  /// A probe; [timeout] bounds each request.
  HttpRemoteSizeProbe({this.timeout = const Duration(seconds: 15)});

  /// The limit of one HEAD request.
  final Duration timeout;

  @override
  Future<int?> sizeOf(String url, {String? token}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final origin = Uri.parse(url);
      var uri = origin;
      for (var hop = 0; hop < 5; hop++) {
        final request = await client.headUrl(uri).timeout(timeout);
        request.followRedirects = false;
        if (token != null && token.isNotEmpty && uri.host == origin.host) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final response = await request.close().timeout(timeout);
        await response.drain<void>();
        final linked = int.tryParse(
          response.headers.value('x-linked-size') ?? '',
        );
        if (linked != null && linked >= 0) return linked;
        final status = response.statusCode;
        if (status >= 300 && status < 400) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) return null;
          uri = uri.resolve(location);
          continue;
        }
        if (status != HttpStatus.ok) return null;
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
