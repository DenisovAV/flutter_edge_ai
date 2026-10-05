/// JavaScript interop for OPFS (Origin Private File System)
///
/// Provides type-safe bindings to the web/opfs_helper.js JavaScript API
/// for storing and streaming large model files (>2GB).
library;

import 'dart:js_interop';

/// OPFS JavaScript API bindings
///
/// Access via: `window.flutterGemmaOPFS`
@JS('flutterGemmaOPFS')
extension type OPFSInterop._(JSObject _) implements JSObject {
  /// Check if a model is cached in OPFS
  ///
  /// @param filename Model filename (cache key)
  /// @returns `Promise<boolean>`
  external JSPromise<JSBoolean> isModelCached(JSString filename);

  /// Get the size of a cached model file
  ///
  /// @param filename Model filename
  /// @returns `Promise<number|null>` Size in bytes, or null if not found
  external JSPromise<JSNumber?> getCachedModelSize(JSString filename);

  /// Download a model to OPFS with progress tracking and cancellation support
  ///
  /// @param url Download URL
  /// @param filename Filename to save in OPFS
  /// @param authToken Optional authentication token (HuggingFace, etc.)
  /// @param onProgress Progress callback (receives 0-100)
  /// @param abortSignal Optional AbortSignal for cancellation
  /// @returns `Promise<boolean>` True on success
  /// @throws Error on download failure, quota exceeded, or cancellation
  external JSPromise<JSBoolean> downloadToOPFS(
    JSString url,
    JSString filename,
    JSString? authToken,
    JSFunction onProgress,
    JSAny? abortSignal,
  );

  /// Get a ReadableStreamDefaultReader for streaming a cached model
  ///
  /// This is passed to MediaPipe's modelAssetBuffer parameter.
  ///
  /// @param filename Model filename in OPFS
  /// @returns `Promise<ReadableStreamDefaultReader>`
  /// @throws Error if file not found
  external JSPromise<JSAny> getStreamReader(JSString filename);

  /// Get a raw ReadableStream for a cached model (no `.getReader()` call).
  ///
  /// Used by `@litert-lm/core` `Engine.create({model: <ReadableStream>})`.
  /// Per upstream docs the engine accepts `string | ReadableStream | Blob`,
  /// and the ReadableStream form is required to avoid Chrome's ~2 GB blob
  /// limit (`ERR_BLOB_OUT_OF_MEMORY`).
  ///
  /// @param filename Model filename in OPFS
  /// @returns `Promise<ReadableStream>`
  /// @throws Error if file not found
  external JSPromise<JSAny> getReadableStream(JSString filename);

  /// Delete a model from OPFS
  ///
  /// @param filename Model filename to delete
  /// @returns `Promise<void>`
  external JSPromise<JSAny> deleteModel(JSString filename);

  /// Get current storage statistics
  ///
  /// @returns Promise<{usage: number, quota: number}> Stats in bytes
  external JSPromise<JSObject> getStorageStats();

  /// Clear all files from OPFS (for testing/development)
  ///
  /// @returns `Promise<number>` Number of files deleted
  external JSPromise<JSNumber> clearAll();
}

/// Helper extension for accessing OPFS from window
@JS('window.flutterGemmaOPFS')
external OPFSInterop get opfsInterop;

/// Storage statistics object
extension type StorageStats._(JSObject _) implements JSObject {
  external JSNumber get usage;
  external JSNumber get quota;
}
