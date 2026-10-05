import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'utils/gemma_log.dart';

/// Comprehensive image processing utilities to prevent AI image corruption
/// and ensure proper vision encoder compatibility.
class ImageProcessor {
  static const int _targetWidth = 896;
  static const int _targetHeight = 896;
  static const int _maxFileSize = 10 * 1024 * 1024; // 10MB limit

  /// Supported image formats for vision encoders
  static const List<String> supportedFormats = ['png', 'jpg', 'jpeg', 'webp'];

  /// Processes an image to ensure compatibility with AI vision encoders
  /// and prevents corruption issues that cause repeating text patterns.
  static Future<ProcessedImage> processImage(
    Uint8List imageBytes, {
    String? originalFormat,
  }) async {
    try {
      gemmaLog('ImageProcessor: Starting image processing...');

      // Step 1: Validate input
      _validateImageBytes(imageBytes);

      // Step 2: Decode image to check format and get dimensions
      final decodedImage = await _decodeImage(imageBytes);
      gemmaLog(
        'ImageProcessor: Original image - Format: ${originalFormat ?? 'unknown'}, '
        'Width: ${decodedImage.width}, Height: ${decodedImage.height}',
      );

      // Step 3: Resize to target dimensions (896x896 for Gemma 3)
      final resizedImage = await _resizeImage(
        decodedImage,
        _targetWidth,
        _targetHeight,
      );
      gemmaLog(
        'ImageProcessor: Image resized to ${_targetWidth}x$_targetHeight',
      );

      // Step 4: Convert to optimal format (PNG for lossless quality)
      final processedBytes = await _encodeToPng(resizedImage);
      gemmaLog('ImageProcessor: Image converted to PNG format');

      // Step 5: Create Base64 encoded version for transmission
      final base64String = _encodeBase64Safe(processedBytes);
      gemmaLog(
        'ImageProcessor: Base64 encoding completed (${base64String.length} chars)',
      );

      // Step 6: Validate final output
      _validateProcessedImage(processedBytes, base64String);

      gemmaLog('ImageProcessor: Image processing completed successfully');

      return ProcessedImage(
        originalBytes: imageBytes,
        processedBytes: processedBytes,
        base64String: base64String,
        width: _targetWidth,
        height: _targetHeight,
        format: 'png',
        originalFormat: originalFormat ?? detectFormat(imageBytes),
      );
    } catch (e) {
      gemmaLog('ImageProcessor: Error processing image - $e');
      throw ImageProcessingException('Failed to process image: $e');
    }
  }

  /// Validates raw image bytes before processing
  static void _validateImageBytes(Uint8List imageBytes) {
    if (imageBytes.isEmpty) {
      throw const ImageProcessingException('Image bytes cannot be empty');
    }

    if (imageBytes.length > _maxFileSize) {
      throw ImageProcessingException(
        'Image size (${imageBytes.length} bytes) exceeds maximum allowed size ($_maxFileSize bytes)',
      );
    }

    // Check for minimum viable image size (roughly 100x100 pixels in most formats)
    if (imageBytes.length < 1024) {
      gemmaLog(
        'ImageProcessor: Warning - Image appears very small (${imageBytes.length} bytes)',
      );
    }
  }

  /// Decodes image to get dimensions and validate format
  static Future<ui.Image> _decodeImage(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frameInfo = await codec.getNextFrame();
      return frameInfo.image;
    } catch (e) {
      throw ImageProcessingException('Failed to decode image: $e');
    }
  }

  /// Resizes image to target dimensions using high-quality filtering
  static Future<ui.Image> _resizeImage(
    ui.Image image,
    int width,
    int height,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Use high-quality filtering for better vision encoder results
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;

    // Calculate scaling to maintain aspect ratio and fill the target dimensions
    final srcWidth = image.width.toDouble();
    final srcHeight = image.height.toDouble();
    final srcAspect = srcWidth / srcHeight;
    final dstAspect = width / height;

    double drawWidth = width.toDouble();
    double drawHeight = height.toDouble();
    double offsetX = 0;
    double offsetY = 0;

    if (srcAspect > dstAspect) {
      // Source is wider - fit to height and crop width
      drawHeight = height.toDouble();
      drawWidth = drawHeight * srcAspect;
      offsetX = (width - drawWidth) / 2;
    } else {
      // Source is taller - fit to width and crop height
      drawWidth = width.toDouble();
      drawHeight = drawWidth / srcAspect;
      offsetY = (height - drawHeight) / 2;
    }

    // Draw the scaled image
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, srcWidth, srcHeight),
      ui.Rect.fromLTWH(offsetX, offsetY, drawWidth, drawHeight),
      paint,
    );

    final picture = recorder.endRecording();
    final resizedImage = await picture.toImage(width, height);
    picture.dispose();

    return resizedImage;
  }

  /// Encodes image to PNG format for optimal vision encoder compatibility
  static Future<Uint8List> _encodeToPng(ui.Image image) async {
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw const ImageProcessingException('Failed to encode image to PNG');
      }
      return byteData.buffer.asUint8List();
    } catch (e) {
      throw ImageProcessingException('PNG encoding failed: $e');
    }
  }

  /// Creates Base64 encoded string with proper formatting for AI model transmission
  static String _encodeBase64Safe(Uint8List bytes) {
    try {
      // Use standard Base64 encoding without line breaks (Base64.NO_WRAP equivalent)
      final base64String = base64.encode(bytes);

      // Remove any whitespace that might cause corruption
      final cleanBase64 = base64String.replaceAll(RegExp(r'\s+'), '');

      // Validate the Base64 string
      if (!_isValidBase64(cleanBase64)) {
        throw const ImageProcessingException('Generated invalid Base64 string');
      }

      return cleanBase64;
    } catch (e) {
      throw ImageProcessingException('Base64 encoding failed: $e');
    }
  }

  /// Validates Base64 string format
  static bool _isValidBase64(String base64String) {
    if (base64String.isEmpty) return false;

    // Check for valid Base64 characters only
    final validBase64Pattern = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');
    if (!validBase64Pattern.hasMatch(base64String)) {
      return false;
    }

    // Check proper padding
    final length = base64String.length;
    if (length % 4 != 0) {
      return false;
    }

    return true;
  }

  /// Validates the processed image output
  static void _validateProcessedImage(
    Uint8List processedBytes,
    String base64String,
  ) {
    if (processedBytes.isEmpty) {
      throw const ImageProcessingException('Processed image bytes are empty');
    }

    if (base64String.isEmpty) {
      throw const ImageProcessingException('Base64 string is empty');
    }

    // Verify Base64 can be decoded back to the same bytes
    try {
      final decodedBytes = base64.decode(base64String);
      if (!_listEquals(decodedBytes, processedBytes)) {
        throw const ImageProcessingException(
          'Base64 encoding/decoding verification failed',
        );
      }
    } catch (e) {
      throw ImageProcessingException('Base64 validation failed: $e');
    }
  }

  /// Detects image format from byte signature
  static String detectFormat(Uint8List bytes) {
    if (bytes.length < 8) return 'unknown';

    // PNG signature: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }

    // JPEG signature: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'jpg';
    }

    // WebP signature: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      if (bytes.length >= 12) {
        final webpSig = String.fromCharCodes(bytes.sublist(8, 12));
        if (webpSig == 'WEBP') return 'webp';
      }
    }

    return 'unknown';
  }

  /// Safe list comparison
  static bool _listEquals<T>(List<T>? a, List<T>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    for (int index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

/// Represents a processed image ready for AI model consumption
class ProcessedImage {
  final Uint8List originalBytes;
  final Uint8List processedBytes;
  final String base64String;
  final int width;
  final int height;
  final String format;
  final String? originalFormat;

  const ProcessedImage({
    required this.originalBytes,
    required this.processedBytes,
    required this.base64String,
    required this.width,
    required this.height,
    required this.format,
    this.originalFormat,
  });

  /// Gets the size of the processed image in bytes
  int get sizeInBytes => processedBytes.length;

  /// Gets the length of the Base64 string
  int get base64Length => base64String.length;

  @override
  String toString() {
    return 'ProcessedImage(format: $format, dimensions: ${width}x$height, '
        'size: $sizeInBytes bytes, base64Length: $base64Length chars, '
        'originalFormat: $originalFormat)';
  }
}

/// Exception thrown when image processing fails
class ImageProcessingException implements Exception {
  final String message;
  final Exception? cause;

  const ImageProcessingException(this.message, [this.cause]);

  @override
  String toString() => 'ImageProcessingException: $message';
}
