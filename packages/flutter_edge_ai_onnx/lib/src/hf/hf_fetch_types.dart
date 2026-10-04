/// A GET returning the response body as text. [OnnxHuggingFaceResolver] accepts
/// one so tests (and apps with their own HTTP stack, proxies, or timeout
/// policy) can replace the default; the defaults live in `hf_fetch_io.dart` /
/// `hf_fetch_web.dart`.
///
/// Contract: follow redirects (Hugging Face answers `/resolve/` paths with a
/// 307 to its CDN), send [headers] verbatim, return the body on any 2xx, and
/// throw [HfFetchException] carrying the status on any other status — check the
/// status before touching the body, so an unreadable error page never loses it.
typedef HfFetch = Future<String> Function(Uri url, Map<String, String> headers);

/// A Hugging Face GET that failed — carries the status so the resolver can tell
/// "repo/path does not exist" (404) apart from auth/network trouble.
class HfFetchException implements Exception {
  final Uri url;
  final int? statusCode;
  final String message;

  const HfFetchException(this.url, this.message, {this.statusCode});

  @override
  String toString() =>
      'HfFetchException'
      '${statusCode != null ? " (HTTP $statusCode)" : ""}: $message [$url]';
}
