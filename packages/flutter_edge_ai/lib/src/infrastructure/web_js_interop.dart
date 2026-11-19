import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:meta/meta.dart' show visibleForTesting;

import 'package:flutter_edge_ai/src/infrastructure/web_cache_interop_stub.dart'
    if (dart.library.js_interop) 'package:flutter_edge_ai/src/infrastructure/web_cache_interop.dart'
    show WebModelBody;

/// JavaScript interop for web-specific download operations.
///
/// Provides authenticated fetch, blob creation, and URL management
/// for downloading private models on the web platform.
class WebJsInterop {
  /// Opens [url] for download, with an `Authorization: Bearer` header when
  /// [authToken] is given, and returns its body still unread.
  ///
  /// Whoever reads the body (the Cache API, a `Blob`) pulls the download
  /// through the browser chunk by chunk; no Dart typed array is built at any
  /// size (see [WebModelBody] for the dart2wasm limit that rules one out).
  /// [onProgress] is called as the body is read, with 0.0 to 1.0 (-1.0 when
  /// the size is unknown) and 1.0 at its end.
  /// Throws [JsInteropException] when the request fails or the server
  /// answers with an error status; a failure while the body is read is the
  /// reader's error.
  Future<WebModelBody> fetchBody(
    String url, {
    String? authToken,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final abortController = _AbortController();
      final response = await _fetch(
        url,
        _fetchOptions(authToken, abortController.signal),
      );
      if (!response.isOk) {
        abortController.abort();
        throw _httpError(response, authenticated: authToken != null);
      }
      return bodyOfResponse(
        response,
        onProgress: onProgress,
        abort: () => abortController.abort(),
      );
    } catch (e) {
      if (e is JsInteropException) rethrow;
      throw JsInteropException('Failed to fetch file: $e');
    }
  }

  /// The body of a fetch `Response`, piped through a stream that counts its
  /// bytes and reports progress; the second half of [fetchBody], which tests
  /// hand a `Response` over a generated stream.
  @visibleForTesting
  WebModelBody bodyOfResponse(
    JSObject response, {
    void Function(double progress)? onProgress,
    void Function()? abort,
  }) {
    final r = response as _Response;
    final contentLength = _getContentLength(r);
    final report = onProgress ?? (_) {};
    var received = 0;
    edgeAiLog(
      '🌊 Starting stream: contentLength=${contentLength ?? "unknown"}',
    );
    final counter = _TransformStream(
      _Transformer(
        transform: ((JSUint8Array chunk, _TransformController controller) {
          received += chunk._byteCount;
          report(
            contentLength != null && contentLength > 0
                ? (received / contentLength).clamp(0.0, 1.0)
                : -1.0,
          );
          controller.enqueue(chunk);
        }).toJS,
        flush: ((_TransformController _) => report(1.0)).toJS,
      ),
    );
    return WebModelBody(
      r.body.pipeThrough(counter),
      bytesRead: () => received,
      abort: abort,
    );
  }

  JsInteropException _httpError(
    _Response response, {
    required bool authenticated,
  }) {
    final statusCode = response.statusCode;
    if (authenticated) {
      switch (statusCode) {
        case 401:
          return JsInteropException(
            'Authentication failed: Invalid or expired token',
            statusCode: 401,
          );
        case 403:
          return JsInteropException(
            'Access denied: Token lacks required permissions',
            statusCode: 403,
          );
        case 404:
          return JsInteropException(
            'Model not found: Check URL is correct',
            statusCode: 404,
          );
      }
      return JsInteropException(
        'HTTP error: ${response.statusMessage}',
        statusCode: statusCode,
      );
    }
    return JsInteropException(
      'Failed to fetch file: ${response.statusMessage}',
      statusCode: statusCode,
    );
  }

  /// Revokes a blob URL to free memory.
  ///
  /// Should be called when the model is closed or replaced.
  void revokeBlobUrl(String blobUrl) {
    try {
      _revokeBlobUrlJs(blobUrl.toJS);
    } catch (e) {
      // Ignore errors during cleanup
      edgeAiLog('Warning: Failed to revoke blob URL: $e');
    }
  }

  // ===== Private Helper Methods =====

  JSObject _fetchOptions(String? authToken, JSObject signal) {
    final options =
        (authToken == null
                    ? <String, Object>{'method': 'GET'}
                    : {
                        'headers': {'Authorization': 'Bearer $authToken'},
                        'method': 'GET',
                      })
                .jsify()!
            as JSObject;
    options['signal'] = signal;
    return options;
  }

  Future<_Response> _fetch(String url, JSAny options) async {
    final promise = _fetchJs(url.toJS, options);
    final jsResponse = await promise.toDart;
    return jsResponse as _Response;
  }

  int? _getContentLength(_Response response) {
    final contentLengthStr = response.headers.getHeader('content-length');
    if (contentLengthStr == null || contentLengthStr.isEmpty) return null;
    return int.tryParse(contentLengthStr);
  }
}

// ===== JS Interop Bindings (Top-level) =====

@JS('fetch')
external JSPromise<JSAny> _fetchJs(JSString url, JSAny options);

@JS('URL.revokeObjectURL')
external void _revokeBlobUrlJs(JSString blobUrl);

/// Exception thrown during JS interop operations.
class JsInteropException implements Exception {
  final String message;
  final int? statusCode;

  JsInteropException(this.message, {this.statusCode});

  @override
  String toString() =>
      'JsInteropException: $message${statusCode != null ? ' (Status: $statusCode)' : ''}';
}

// ===== Extension Types for Response Handling =====

extension type _Response._(JSObject _) implements JSObject {
  external JSBoolean get ok;
  external JSNumber get status;
  external JSString get statusText;
  external _Headers get headers;
  external _Body get body;

  bool get isOk => ok.toDart;
  int get statusCode => status.toDartInt;
  String get statusMessage => statusText.toDart;
}

extension type _Headers._(JSObject _) implements JSObject {
  external JSString? get(JSString name);

  String? getHeader(String name) {
    final result = get(name.toJS);
    if (result == null) return null;
    return result.toDart;
  }
}

extension type _Body._(JSObject _) implements JSObject {
  external JSObject pipeThrough(_TransformStream transform);
}

@JS('AbortController')
extension type _AbortController._(JSObject _) implements JSObject {
  external factory _AbortController();
  external JSObject get signal;
  external void abort();
}

@JS('TransformStream')
extension type _TransformStream._(JSObject _) implements JSObject {
  external factory _TransformStream(_Transformer transformer);
}

extension type _Transformer._(JSObject _) implements JSObject {
  external factory _Transformer({JSFunction transform, JSFunction flush});
}

extension type _TransformController._(JSObject _) implements JSObject {
  external void enqueue(JSUint8Array chunk);
}

extension on JSUint8Array {
  @JS('length')
  external int get _byteCount;
}
