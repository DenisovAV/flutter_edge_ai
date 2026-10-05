import 'dart:convert';
import 'dart:io';

import 'hf_fetch_types.dart';

/// Default Hugging Face GET on `dart:io` platforms.
///
/// A plain [HttpClient] — deliberately not the plugin's model-download stack
/// (background_downloader is sized for multi-GB files, not a few KB of JSON).
/// [HttpClient] follows redirects for GET by default, which matters here:
/// Hugging Face answers `/resolve/` paths with a 307 to its CDN.
Future<String> defaultHfFetch(Uri url, Map<String, String> headers) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    headers.forEach(request.headers.set);
    final response = await request.close();
    final status = response.statusCode;
    // Status before body: an error page's bytes are not the signal, and one
    // that fails to decode must not turn a 404 into a status-less failure.
    if (status < 200 || status >= 300) {
      try {
        await response.drain<void>();
      } catch (_) {
        // A body that cannot even be read changes nothing: status is the answer.
      }
      throw HfFetchException(
        url,
        'GET failed with HTTP $status',
        statusCode: status,
      );
    }
    return await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
  } on HfFetchException {
    rethrow;
  } on Exception catch (e) {
    throw HfFetchException(url, 'GET failed: $e');
  } finally {
    client.close();
  }
}
