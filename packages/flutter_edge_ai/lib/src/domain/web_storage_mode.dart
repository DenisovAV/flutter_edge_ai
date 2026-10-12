/// Storage mode for web platform models
///
/// Controls how model files are stored and loaded on the web platform.
/// Different modes are optimized for different model sizes and use cases.
enum WebStorageMode {
  /// Cache API with Blob URLs (default) - for models <2GB
  ///
  /// Uses browser Cache API for persistent storage. Models are downloaded
  /// as ArrayBuffer and converted to Blob URLs for MediaPipe.
  ///
  /// Advantages:
  /// - Fast model loading (cached in browser)
  /// - Persistent across page reloads
  /// - Works offline after initial download
  ///
  /// Limitations:
  /// - ArrayBuffer size limit (~2GB in most browsers)
  /// - Not suitable for large models (E4B, 7B, 27B)
  ///
  /// Use for: Gemma 2B, 3N models, most quantized models
  cacheApi,

  /// OPFS with streaming - for models >2GB (E4B, 7B, 27B)
  ///
  /// Uses Origin Private File System with ReadableStream to bypass
  /// ArrayBuffer memory limits. Models are streamed directly to OPFS
  /// and loaded via ReadableStreamDefaultReader.
  ///
  /// Advantages:
  /// - No memory limits (can handle 4GB+ models)
  /// - Persistent across page reloads
  /// - Memory-efficient streaming
  ///
  /// Limitations:
  /// - Requires modern browser with OPFS support
  /// - Slightly slower initial load
  ///
  /// Use for: Large models (E4B 4.2GB, Gemma 7B, etc.)
  streaming,

  /// No caching (ephemeral) - model URLs stored in memory only
  ///
  /// Blob URLs and metadata are stored in memory and cleared on
  /// hot restart or page reload. Models must be re-downloaded
  /// each time.
  ///
  /// Advantages:
  /// - No persistent storage
  /// - Fast development iteration (hot restart cleans state)
  ///
  /// Limitations:
  /// - Models re-downloaded on each page reload
  /// - Not suitable for production
  ///
  /// Use for: Development, testing, privacy-sensitive scenarios
  none,
}
