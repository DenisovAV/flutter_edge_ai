import 'dart:convert';
import 'dart:io';

import 'manifest_fetch_types.dart';

/// Default manifest GET on `dart:io` platforms.
///
/// A plain [HttpClient] — deliberately not the plugin's model-download stack
/// (background_downloader is sized for multi-GB files, not a few KB of JSON).
/// [HttpClient] follows redirects for GET by default, which matters here:
/// Hugging Face answers `/resolve/` paths with a 307 to its CDN.
Future<String> defaultManifestFetch(
  Uri url,
  Map<String, String> headers,
) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    headers.forEach(request.headers.set);
    final response = await request.close();
    final status = response.statusCode;
    // Status before body: an error page's bytes are not the signal, and one
    // that fails to decode must not turn a 404 into a status-less failure.
    // Any 2xx is success, as on web (`Response.ok`).
    if (status < 200 || status >= 300) {
      try {
        // Consume the error body so the connection is released; the bytes
        // themselves are irrelevant.
        await response.drain<void>();
      } catch (_) {
        // A body that cannot even be read changes nothing: the status is
        // the answer, and the client is closed below.
      }
      throw ManifestFetchException(
        url,
        'GET failed with HTTP $status',
        statusCode: status,
      );
    }
    // Decode with replacement, as the browser's `Response.text()` does, so
    // both arms hand the parser the same body for the same bytes.
    return await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
  } on ManifestFetchException {
    rethrow;
  } on Exception catch (e) {
    throw ManifestFetchException(url, 'GET failed: $e');
  } finally {
    client.close();
  }
}
