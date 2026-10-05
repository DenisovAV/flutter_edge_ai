import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'hf_fetch_types.dart';

/// Default Hugging Face GET on web: the browser's `fetch`. The browser follows
/// the Hugging Face `/resolve/` 307 itself; `huggingface.co` serves CORS headers
/// on these endpoints (the web model-download path relies on that already).
Future<String> defaultHfFetch(Uri url, Map<String, String> headers) async {
  final options = JSObject();
  if (headers.isNotEmpty) {
    final jsHeaders = JSObject();
    headers.forEach((k, v) => jsHeaders.setProperty(k.toJS, v.toJS));
    options.setProperty('headers'.toJS, jsHeaders);
  }
  _Response response;
  try {
    response =
        (await _fetchJs(url.toString().toJS, options).toDart) as _Response;
  } catch (e) {
    throw HfFetchException(url, 'GET failed: $e');
  }
  final status = response.status.toDartInt;
  if (!response.ok.toDart) {
    throw HfFetchException(
      url,
      'GET failed with HTTP $status',
      statusCode: status,
    );
  }
  try {
    return (await response.text().toDart).toDart;
  } catch (e) {
    throw HfFetchException(url, 'reading response body failed: $e');
  }
}

@JS('fetch')
external JSPromise<JSAny> _fetchJs(JSString url, JSAny options);

extension type _Response(JSObject _) implements JSObject {
  external JSBoolean get ok;
  external JSNumber get status;
  external JSPromise<JSString> text();
}
