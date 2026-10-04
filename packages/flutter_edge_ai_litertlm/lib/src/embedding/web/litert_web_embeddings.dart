/// Dart interop layer for LiteRT.js embeddings
///
/// This file provides type-safe Dart bindings to the JavaScript
/// LiteRT embeddings API exposed in web/litert_embeddings.js
library;

import 'dart:js_interop';

/// External JavaScript functions exposed from web/litert_embeddings.js
@JS('loadLiteRtEmbeddings')
external JSPromise _loadLiteRtEmbeddingsJS(
  JSString modelPath,
  JSString tokenizerPath,
  JSString? wasmPath,
);

@JS('generateEmbedding')
external JSPromise _generateEmbeddingJS(JSString text);

@JS('generateDocumentEmbedding')
external JSPromise _generateDocumentEmbeddingJS(JSString text);

@JS('generateEmbeddings')
external JSPromise _generateEmbeddingsJS(JSArray texts);

@JS('getLiteRtEmbeddingDimension')
external JSNumber _getLiteRtEmbeddingDimensionJS();

@JS('cleanupLiteRtEmbeddings')
external JSPromise _cleanupLiteRtEmbeddingsJS();

@JS('isLiteRtEmbeddingsInitialized')
external JSBoolean _isLiteRtEmbeddingsInitializedJS();

/// Extension type for JSFloat32Array (not provided by dart:js_interop)
extension type JSFloat32Array._(JSObject _) implements JSObject {
  external JSNumber get length;
  external JSNumber operator [](JSNumber index);
}

/// Extension type for JSArrays of Float32Arrays
extension type JSFloat32Arrays._(JSArray _) implements JSArray {
  JSFloat32Array getAt(int index) {
    // Use the JSArray subscript operator which accepts int directly
    return (this as JSArray)[index] as JSFloat32Array;
  }

  // JSArray.length is already int in newer Dart versions
  int get arrayLength {
    return (this as JSArray).length;
  }
}

/// Type-safe Dart wrapper for LiteRT embeddings
class LiteRTWebEmbeddings {
  // Private constructor to prevent instantiation
  LiteRTWebEmbeddings._();

  /// Initialize LiteRT embeddings with model and tokenizer paths.
  ///
  /// Must be called before generating embeddings.
  ///
  /// [modelPath] - Path to .tflite model file
  /// [tokenizerPath] - Path to sentencepiece.model file
  /// [wasmPath] - Optional path to WASM files (defaults to /node_modules/@litertjs/core/wasm/)
  ///
  /// Note: Sequence length is auto-detected from model input shape (like iOS/Android)
  ///
  /// Throws [Exception] if initialization fails
  static Future<void> initialize(
    String modelPath,
    String tokenizerPath, {
    String? wasmPath,
  }) async {
    try {
      await _loadLiteRtEmbeddingsJS(
        modelPath.toJS,
        tokenizerPath.toJS,
        wasmPath?.toJS,
      ).toDart;
    } catch (e) {
      throw Exception('Failed to initialize LiteRT embeddings: $e');
    }
  }

  /// Generate embedding for a single text.
  ///
  /// [text] - Text to embed
  ///
  /// Returns `List<double>` - Embedding vector (768 dimensions)
  ///
  /// Throws [Exception] if not initialized or generation fails
  static Future<List<double>> generateEmbedding(String text) async {
    if (!isInitialized()) {
      throw StateError(
        'LiteRT embeddings not initialized. Call initialize() first.',
      );
    }

    if (text.trim().isEmpty) {
      throw ArgumentError('Text must not be empty');
    }

    try {
      // Call JS function and get Float32Array
      final jsResult = await _generateEmbeddingJS(text.toJS).toDart;

      // Convert JS Float32Array to Dart List<double>
      final jsArray = jsResult as JSFloat32Array;
      final length = jsArray.length.toDartInt;
      final result = List<double>.filled(length, 0.0);

      for (int i = 0; i < length; i++) {
        result[i] = jsArray[i.toJS].toDartDouble;
      }

      return result;
    } catch (e) {
      throw Exception('Failed to generate embedding: $e');
    }
  }

  /// Generate document embedding for a single text (uses document prefix).
  ///
  /// [text] - Text to embed
  ///
  /// Returns `List<double>` - Embedding vector (768 dimensions)
  ///
  /// Throws [Exception] if not initialized or generation fails
  static Future<List<double>> generateDocumentEmbedding(String text) async {
    if (!isInitialized()) {
      throw StateError(
        'LiteRT embeddings not initialized. Call initialize() first.',
      );
    }

    if (text.trim().isEmpty) {
      throw ArgumentError('Text must not be empty');
    }

    try {
      final jsResult = await _generateDocumentEmbeddingJS(text.toJS).toDart;
      final jsArray = jsResult as JSFloat32Array;
      final length = jsArray.length.toDartInt;
      final result = List<double>.filled(length, 0.0);

      for (int i = 0; i < length; i++) {
        result[i] = jsArray[i.toJS].toDartDouble;
      }

      return result;
    } catch (e) {
      throw Exception('Failed to generate document embedding: $e');
    }
  }

  /// Generate embeddings for multiple texts (batch processing).
  ///
  /// [texts] - List of texts to embed
  ///
  /// Returns `List<List<double>>` - List of embedding vectors
  ///
  /// Throws [Exception] if not initialized or generation fails
  static Future<List<List<double>>> generateEmbeddings(
    List<String> texts,
  ) async {
    if (!isInitialized()) {
      throw StateError(
        'LiteRT embeddings not initialized. Call initialize() first.',
      );
    }

    if (texts.isEmpty) {
      throw ArgumentError('texts must not be empty');
    }

    for (final text in texts) {
      if (text.trim().isEmpty) {
        throw ArgumentError('All texts must not be empty');
      }
    }

    try {
      // Convert Dart List<String> to JS Array
      final jsTexts = texts.map((t) => t.toJS).toList().toJS;

      // Call JS function and get array of Float32Arrays
      final jsResult = await _generateEmbeddingsJS(jsTexts).toDart;

      // Convert JS array of Float32Arrays to Dart List<List<double>>
      final jsArrays = jsResult as JSFloat32Arrays;
      final result = <List<double>>[];

      for (int i = 0; i < jsArrays.arrayLength; i++) {
        final jsEmbedding = jsArrays.getAt(i);
        final embeddingLength = jsEmbedding.length.toDartInt;
        final embedding = List<double>.filled(embeddingLength, 0.0);

        for (int j = 0; j < embeddingLength; j++) {
          embedding[j] = jsEmbedding[j.toJS].toDartDouble;
        }

        result.add(embedding);
      }

      return result;
    } catch (e) {
      throw Exception('Failed to generate embeddings: $e');
    }
  }

  /// Get the dimension of embeddings generated by this model.
  ///
  /// Returns [int] - Embedding dimension (768)
  static int getDimension() {
    return _getLiteRtEmbeddingDimensionJS().toDartInt;
  }

  /// Check if LiteRT embeddings are initialized.
  ///
  /// Returns [bool] - true if initialized, false otherwise
  static bool isInitialized() {
    return _isLiteRtEmbeddingsInitializedJS().toDart;
  }

  /// Cleanup LiteRT embeddings and release resources.
  ///
  /// Should be called when embeddings are no longer needed.
  static Future<void> dispose() async {
    try {
      await _cleanupLiteRtEmbeddingsJS().toDart;
    } catch (e) {
      throw Exception('Failed to cleanup LiteRT embeddings: $e');
    }
  }
}
