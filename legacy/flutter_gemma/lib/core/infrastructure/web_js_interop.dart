import 'dart:async';
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/foundation.dart';

/// Response from fetch operations
class FetchResponse {
  final Uint8List data;
  final int statusCode;

  FetchResponse(this.data, this.statusCode);
}

/// JavaScript interop for web-specific download operations.
///
/// Provides authenticated fetch, blob creation, and URL management
/// for downloading private models on the web platform.
class WebJsInterop {
  /// Fetches a public file (no authentication).
  ///
  /// Returns FetchResponse with downloaded data.
  /// Throws [JsInteropException] on fetch errors.
  Future<FetchResponse> fetchFile(String url) async {
    try {
      // Fetch without auth
      final promise = _fetchJs(url.toJS, JSObject());
      final jsResponse = await promise.toDart;
      final response = jsResponse as _Response;

      // Check response status
      if (!response.isOk) {
        throw JsInteropException(
          'Failed to fetch file: ${response.statusMessage}',
          statusCode: response.statusCode,
        );
      }

      // Stream response body
      final chunks = await _streamResponseBody(
        response,
        _getContentLength(response),
        (_) {}, // No progress callback for public files
      );

      // Concatenate chunks
      final totalLength = chunks.fold<int>(
        0,
        (sum, chunk) => sum + chunk.length,
      );
      final data = Uint8List(totalLength);
      int offset = 0;
      for (final chunk in chunks) {
        data.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }

      return FetchResponse(data, response.statusCode);
    } catch (e) {
      if (e is JsInteropException) rethrow;
      throw JsInteropException('Failed to fetch file: $e');
    }
  }

  /// Fetches a file with authentication.
  ///
  /// Returns FetchResponse with downloaded data.
  /// Calls [onProgress] with download progress (0.0 to 1.0).
  /// Throws [JsInteropException] on fetch errors.
  Future<FetchResponse> fetchWithAuth(
    String url,
    String authToken, {
    required void Function(double progress) onProgress,
  }) async {
    try {
      // Create fetch options with auth header
      final options = _createFetchOptions(authToken);

      // Fetch with auth
      final response = await _fetch(url, options);

      // Check response status
      if (!response.isOk) {
        final statusCode = response.statusCode;
        final statusText = response.statusMessage;

        if (statusCode == 401) {
          throw JsInteropException(
            'Authentication failed: Invalid or expired token',
            statusCode: 401,
          );
        } else if (statusCode == 403) {
          throw JsInteropException(
            'Access denied: Token lacks required permissions',
            statusCode: 403,
          );
        } else if (statusCode == 404) {
          throw JsInteropException(
            'Model not found: Check URL is correct',
            statusCode: 404,
          );
        } else {
          throw JsInteropException(
            'HTTP error: $statusText',
            statusCode: statusCode,
          );
        }
      }

      // Stream response body with progress
      final chunks = await _streamResponseBody(
        response,
        _getContentLength(response),
        onProgress,
      );

      // Concatenate chunks
      final totalLength = chunks.fold<int>(
        0,
        (sum, chunk) => sum + chunk.length,
      );
      final data = Uint8List(totalLength);
      int offset = 0;
      for (final chunk in chunks) {
        data.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }

      return FetchResponse(data, response.statusCode);
    } catch (e) {
      if (e is JsInteropException) rethrow;
      throw JsInteropException('Failed to fetch authenticated file: $e');
    }
  }

  /// Fetches a file with authentication and creates a blob URL.
  ///
  /// Returns a blob URL that can be used with MediaPipe.
  /// Calls [onProgress] with download progress (0.0 to 1.0).
  ///
  /// Throws [JsInteropException] on fetch errors (network, auth, etc.).
  Future<String> fetchWithAuthAndCreateBlob(
    String url,
    String authToken, {
    required void Function(double progress) onProgress,
  }) async {
    try {
      // 1. Create fetch options with auth header
      final options = _createFetchOptions(authToken);

      // 2. Fetch with auth
      final response = await _fetch(url, options);

      // 3. Check response status
      if (!response.isOk) {
        final statusCode = response.statusCode;
        final statusText = response.statusMessage;

        if (statusCode == 401) {
          throw JsInteropException(
            'Authentication failed: Invalid or expired token',
            statusCode: 401,
          );
        } else if (statusCode == 403) {
          throw JsInteropException(
            'Access denied: Token lacks required permissions',
            statusCode: 403,
          );
        } else if (statusCode == 404) {
          throw JsInteropException(
            'Model not found: Check URL is correct',
            statusCode: 404,
          );
        } else {
          throw JsInteropException(
            'HTTP $statusCode: $statusText',
            statusCode: statusCode,
          );
        }
      }

      // 4. Get content length for progress
      final contentLength = _getContentLength(response);

      // 5. Stream response body
      final chunks = await _streamResponseBody(
        response,
        contentLength,
        onProgress,
      );

      // 6. Create blob from chunks
      final blob = _createBlob(chunks);

      // 7. Create and return blob URL
      final blobUrl = _createBlobUrl(blob);

      return blobUrl;
    } catch (e) {
      if (e is JsInteropException) rethrow;

      // Check for common error patterns
      final errorStr = e.toString();
      if (errorStr.contains('CORS') || errorStr.contains('Access-Control')) {
        throw JsInteropException(
          'CORS error: Server does not allow requests from this origin. '
          'For HuggingFace models, ensure you have access to the repository.',
        );
      } else if (errorStr.contains('network') ||
          errorStr.contains('Failed to fetch')) {
        throw JsInteropException(
          'Network error: Check your internet connection and try again.',
        );
      } else {
        throw JsInteropException('Fetch failed: $e');
      }
    }
  }

  /// Revokes a blob URL to free memory.
  ///
  /// Should be called when the model is closed or replaced.
  void revokeBlobUrl(String blobUrl) {
    try {
      _revokeBlobUrlJs(blobUrl.toJS);
    } catch (e) {
      // Ignore errors during cleanup
      gemmaLog('Warning: Failed to revoke blob URL: $e');
    }
  }

  // ===== Private Helper Methods =====

  JSAny _createFetchOptions(String authToken) {
    final headersMap = {'Authorization': 'Bearer $authToken'};

    final optionsMap = {'headers': headersMap, 'method': 'GET'};

    return optionsMap.jsify()!;
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

  Future<List<Uint8List>> _streamResponseBody(
    _Response response,
    int? contentLength,
    void Function(double) onProgress,
  ) async {
    final reader = response.body.getReader();
    final chunks = <Uint8List>[];
    int bytesReceived = 0;

    gemmaLog('🌊 Starting stream: contentLength=${contentLength ?? "unknown"}');

    // Warn about large files
    if (contentLength != null && contentLength > 2 * 1024 * 1024 * 1024) {
      gemmaLog(
        'Warning: Large file detected (${contentLength ~/ 1024 / 1024}MB). '
        'May encounter memory limits on some browsers.',
      );
    }

    try {
      while (true) {
        final result = await reader.read().toDart;

        if (result.isDone) break;

        final chunk = (result.value as JSUint8Array).toDart;
        chunks.add(chunk);
        bytesReceived += chunk.length;

        if (contentLength != null && contentLength > 0) {
          final progress = bytesReceived / contentLength;
          onProgress(progress.clamp(0.0, 1.0));
        } else {
          // Indeterminate progress
          onProgress(-1.0);
        }
      }

      // Final progress
      onProgress(1.0);
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('out of memory') ||
          errorStr.contains('allocation') ||
          errorStr.contains('quota')) {
        throw JsInteropException(
          'Out of memory: File too large for this browser/device. '
          'Try using a smaller model or native platform.',
        );
      } else if (errorStr.contains('network') || errorStr.contains('timeout')) {
        throw JsInteropException(
          'Network interruption: Download incomplete. '
          'Please check your connection and retry.',
        );
      }
      rethrow;
    }

    return chunks;
  }

  JSAny _createBlob(List<Uint8List> chunks) {
    final jsChunks = chunks.map((c) => c.toJS).toList().toJS;
    final options = {'type': 'application/octet-stream'}.jsify()!;

    // Use callConstructor to properly invoke Blob constructor with 'new'
    final blobConstructor = globalContext['Blob'] as JSFunction;
    return blobConstructor.callAsConstructor(jsChunks, options);
  }

  String _createBlobUrl(JSAny blob) {
    return _createObjectUrlJs(blob).toDart;
  }
}

// ===== JS Interop Bindings (Top-level) =====

@JS('fetch')
external JSPromise<JSAny> _fetchJs(JSString url, JSAny options);

@JS('URL.createObjectURL')
external JSString _createObjectUrlJs(JSAny blob);

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
  external _ReadableStreamReader getReader();
}

extension type _ReadableStreamReader._(JSObject _) implements JSObject {
  external JSPromise<_ReadResult> read();
}

extension type _ReadResult._(JSObject _) implements JSObject {
  external JSBoolean get done;
  external JSAny get value;

  bool get isDone => done.toDart;
}
