/// A GET returning the response body as text. [LitertlmManifestResolver]
/// accepts one so tests (and apps with their own HTTP stack, proxies, or
/// timeout policy) can replace the default; the defaults live in
/// `manifest_fetch_io.dart` / `manifest_fetch_web.dart`.
///
/// Contract: follow redirects (Hugging Face answers `/resolve/` paths with a
/// 307 to its CDN), send [headers] verbatim, return the body on any 2xx, and
/// throw [ManifestFetchException] carrying the status on any other status —
/// check the status before touching the body, so an unreadable error page
/// never loses it.
typedef ManifestFetch =
    Future<String> Function(Uri url, Map<String, String> headers);

/// A manifest GET that failed — carries the status so the resolver can tell
/// "repo ships no manifest" (404) apart from auth/network trouble.
class ManifestFetchException implements Exception {
  final Uri url;
  final int? statusCode;
  final String message;

  const ManifestFetchException(this.url, this.message, {this.statusCode});

  @override
  String toString() =>
      'ManifestFetchException'
      '${statusCode != null ? " (HTTP $statusCode)" : ""}: $message [$url]';
}
