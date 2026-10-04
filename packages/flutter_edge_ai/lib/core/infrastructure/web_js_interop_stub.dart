import 'dart:typed_data';

/// Stub implementation for non-web platforms
class WebJsInterop {
  WebJsInterop() {
    throw UnsupportedError('WebJsInterop is only available on web platform');
  }

  Future<FetchFileResponse> fetchFile(String url, {String? authToken}) {
    throw UnsupportedError('WebJsInterop is only available on web platform');
  }

  Future<Uint8List> fetchFileAsBytes(String url, {String? authToken}) {
    throw UnsupportedError('WebJsInterop is only available on web platform');
  }
}

/// Stub response class
class FetchFileResponse {
  final Uint8List data;
  final int statusCode;
  final String statusText;
  final Map<String, String> headers;

  FetchFileResponse({
    required this.data,
    required this.statusCode,
    required this.statusText,
    required this.headers,
  });
}
