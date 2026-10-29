import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';

/// The size of a file on a server before it is downloaded: one HEAD request.
///
/// Internal. A bundle installer uses it to weight its progress by bytes when
/// the files are not downloaded yet.
abstract interface class RemoteSizeProbe {
  /// Bytes of the file at [url], or null when the server does not say (no
  /// size header, a status other than 200 after the redirects, an error, a
  /// timeout, a cancel). [token] is sent as a bearer token to [url]'s origin
  /// (scheme, host and port) only, never to another one a redirect leads to.
  /// A cancel of [cancelToken] ends the request at once.
  ///
  /// On the final 200 answer `X-Linked-Size` (Hugging Face) is preferred over
  /// `Content-Length`.
  Future<int?> sizeOf(String url, {String? token, CancelToken? cancelToken});
}
