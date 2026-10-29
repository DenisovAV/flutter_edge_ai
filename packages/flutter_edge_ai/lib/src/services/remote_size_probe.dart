/// The size of a file on a server before it is downloaded: one HEAD request.
///
/// Internal. A bundle installer uses it to weight its progress by bytes when
/// the files are not downloaded yet.
abstract interface class RemoteSizeProbe {
  /// Bytes of the file at [url], or null when the server does not say (no
  /// size header, an error, a timeout). [token] is sent as a bearer token to
  /// [url]'s host only, never to a host a redirect leads to.
  ///
  /// A Hugging Face `resolve/` URL answers with a redirect that carries the
  /// file's size as `X-Linked-Size`; that is preferred over a
  /// `Content-Length`, which on the redirect itself describes the redirect.
  Future<int?> sizeOf(String url, {String? token});
}
