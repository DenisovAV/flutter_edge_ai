// Web stub for litert_lm_client.dart
//
// Web build never reaches FFI code paths — the web plugin (FlutterGemmaWeb)
// registers itself as FlutterGemmaPlugin.instance via registerWith(), so the
// mobile/desktop branch in mobile/flutter_gemma_mobile.dart never executes.
// This stub exists purely so the import graph compiles on web (no dart:ffi).

class LiteRtLmFfiClient {
  LiteRtLmFfiClient() {
    throw UnsupportedError(
      'LiteRtLmFfiClient is not available on web — use FlutterGemmaWeb instead.',
    );
  }

  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 2048,
    String? cacheDir,
    bool enableVision = false,
    int maxNumImages = 0,
    bool enableAudio = false,
    bool? enableSpeculativeDecoding,
    int? activationDataType,
  }) => throw UnsupportedError('web stub — never instantiated');

  // Referenced by the FFI fallback runtime in flutter_gemma_mobile.dart
  // (shutdownClient callback). Present so the web import graph compiles;
  // never actually invoked because FlutterGemmaWeb owns the web path.
  void shutdown() => throw UnsupportedError('web stub — never instantiated');
}
