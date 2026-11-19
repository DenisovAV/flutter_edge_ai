/// Stub implementation for non-web platforms
library;

import 'package:flutter_edge_ai/src/infrastructure/web_cache_interop_stub.dart';

/// Stub implementation for non-web platforms
class WebJsInterop {
  WebJsInterop() {
    throw UnsupportedError('WebJsInterop is only available on web platform');
  }

  Future<WebModelBody> fetchBody(
    String url, {
    String? authToken,
    void Function(double progress)? onProgress,
  }) {
    throw UnsupportedError('WebJsInterop is only available on web platform');
  }
}
