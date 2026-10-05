import 'package:flutter/foundation.dart';
import 'image_processor.dart';
import 'utils/gemma_log.dart';

/// Validates images for compatibility with AI vision encoders to prevent
/// corruption that causes models to interpret images as repeating text patterns.
class VisionEncoderValidator {
  /// Gemma 3 vision encoder specifications
  static const Gemma3Specs gemma3Specs = Gemma3Specs();

  /// General vision encoder specifications
  static const GeneralVisionSpecs generalSpecs = GeneralVisionSpecs();

  /// Validates an image for compatibility with the specified vision encoder
  static ValidationResult validateForEncoder({
    required Uint8List imageBytes,
    required VisionEncoderType encoderType,
    String? originalFormat,
  }) {
    try {
      gemmaLog('VisionEncoderValidator: Validating image for $encoderType...');

      // Get appropriate specifications
      final specs = _getSpecsForEncoder(encoderType);

      // Perform comprehensive validation
      final formatValidation = _validateFormat(
        imageBytes,
        originalFormat,
        specs,
      );
      if (!formatValidation.isValid) {
        return formatValidation;
      }

      final sizeValidation = _validateSize(imageBytes, specs);
      if (!sizeValidation.isValid) {
        return sizeValidation;
      }

      final dimensionValidation = _validateDimensions(imageBytes, specs);
      if (!dimensionValidation.isValid) {
        return dimensionValidation;
      }

      final compatibilityValidation = _validateEncoderCompatibility(
        imageBytes,
        encoderType,
      );
      if (!compatibilityValidation.isValid) {
        return compatibilityValidation;
      }

      gemmaLog(
        'VisionEncoderValidator: Image validation passed for $encoderType',
      );

      return ValidationResult(
        isValid: true,
        encoderType: encoderType,
        message: 'Image is compatible with ${encoderType.name} vision encoder',
        suggestions: [],
      );
    } catch (e) {
      gemmaLog('VisionEncoderValidator: Validation failed - $e');
      return ValidationResult(
        isValid: false,
        encoderType: encoderType,
        message: 'Validation failed: $e',
        suggestions: [
          'Check image format and try processing with ImageProcessor',
        ],
      );
    }
  }

  /// Gets specifications for the specified encoder type
  static VisionSpecs _getSpecsForEncoder(VisionEncoderType encoderType) {
    switch (encoderType) {
      case VisionEncoderType.gemma3SigLIP:
        return gemma3Specs;
      case VisionEncoderType.general:
        return generalSpecs;
    }
  }

  /// Validates image format compatibility
  static ValidationResult _validateFormat(
    Uint8List imageBytes,
    String? originalFormat,
    VisionSpecs specs,
  ) {
    final detectedFormat = ImageProcessor.detectFormat(imageBytes);
    final format = originalFormat ?? detectedFormat;

    if (!specs.supportedFormats.contains(format)) {
      return ValidationResult(
        isValid: false,
        encoderType: specs.encoderType,
        message:
            'Unsupported format: $format. Supported: ${specs.supportedFormats.join(', ')}',
        suggestions: ['Convert image to PNG format using ImageProcessor'],
      );
    }

    return ValidationResult(
      isValid: true,
      encoderType: specs.encoderType,
      message: 'Format $format is supported',
      suggestions: [],
    );
  }

  /// Validates image file size
  static ValidationResult _validateSize(
    Uint8List imageBytes,
    VisionSpecs specs,
  ) {
    final sizeInBytes = imageBytes.length;
    final sizeInMB = sizeInBytes / (1024 * 1024);

    if (sizeInBytes > specs.maxFileSize) {
      return ValidationResult(
        isValid: false,
        encoderType: specs.encoderType,
        message:
            'File size (${sizeInMB.toStringAsFixed(2)}MB) exceeds maximum (${specs.maxFileSizeMB}MB)',
        suggestions: ['Resize or compress the image'],
      );
    }

    if (sizeInBytes < specs.minFileSize) {
      return ValidationResult(
        isValid: false,
        encoderType: specs.encoderType,
        message:
            'File size ($sizeInBytes bytes) is too small, may be corrupted',
        suggestions: ['Check if image is valid and not corrupted'],
      );
    }

    return ValidationResult(
      isValid: true,
      encoderType: specs.encoderType,
      message: 'File size (${sizeInMB.toStringAsFixed(2)}MB) is acceptable',
      suggestions: [],
    );
  }

  /// Validates image dimensions
  static ValidationResult _validateDimensions(
    Uint8List imageBytes,
    VisionSpecs specs,
  ) {
    try {
      // This is a simplified check - in a real implementation,
      // you would decode the image to get actual dimensions
      final estimatedDimensions = _estimateDimensions(imageBytes);

      if (estimatedDimensions.width < specs.minWidth ||
          estimatedDimensions.height < specs.minHeight) {
        return ValidationResult(
          isValid: false,
          encoderType: specs.encoderType,
          message:
              'Image dimensions too small: ${estimatedDimensions.width}x${estimatedDimensions.height}',
          suggestions: ['Use a higher resolution image'],
        );
      }

      if (estimatedDimensions.width > specs.maxWidth ||
          estimatedDimensions.height > specs.maxHeight) {
        return ValidationResult(
          isValid: false,
          encoderType: specs.encoderType,
          message:
              'Image dimensions too large: ${estimatedDimensions.width}x${estimatedDimensions.height}',
          suggestions: [
            'Resize image to ${specs.targetWidth}x${specs.targetHeight}',
          ],
        );
      }

      return ValidationResult(
        isValid: true,
        encoderType: specs.encoderType,
        message:
            'Dimensions ${estimatedDimensions.width}x${estimatedDimensions.height} are acceptable',
        suggestions: [],
      );
    } catch (e) {
      return ValidationResult(
        isValid: false,
        encoderType: specs.encoderType,
        message: 'Could not validate dimensions: $e',
        suggestions: ['Process image with ImageProcessor first'],
      );
    }
  }

  /// Estimates image dimensions from file size (rough approximation)
  static EstimatedDimensions _estimateDimensions(Uint8List imageBytes) {
    final sizeInBytes = imageBytes.length;

    // Very rough estimation based on typical compression ratios
    // This is not accurate but sufficient for validation
    if (sizeInBytes < 50 * 1024) {
      // < 50KB
      return const EstimatedDimensions(200, 200);
    } else if (sizeInBytes < 200 * 1024) {
      // < 200KB
      return const EstimatedDimensions(400, 400);
    } else if (sizeInBytes < 500 * 1024) {
      // < 500KB
      return const EstimatedDimensions(600, 600);
    } else {
      return const EstimatedDimensions(800, 800);
    }
  }

  /// Validates encoder-specific compatibility requirements
  static ValidationResult _validateEncoderCompatibility(
    Uint8List imageBytes,
    VisionEncoderType encoderType,
  ) {
    switch (encoderType) {
      case VisionEncoderType.gemma3SigLIP:
        return _validateGemma3Compatibility(imageBytes);
      case VisionEncoderType.general:
        return _validateGeneralCompatibility(imageBytes);
    }
  }

  /// Validates compatibility with Gemma 3 SigLIP encoder
  static ValidationResult _validateGemma3Compatibility(Uint8List imageBytes) {
    // Gemma 3 specific requirements
    final issues = <String>[];
    final suggestions = <String>[];

    // Check for potential corruption indicators
    if (_hasCorruptionIndicators(imageBytes)) {
      issues.add('Image shows signs of potential corruption');
      suggestions.add('Re-process image with ImageProcessor');
    }

    // Check for proper encoding
    if (!_hasProperEncoding(imageBytes)) {
      issues.add('Image encoding may not be optimal for SigLIP');
      suggestions.add('Convert to PNG format');
    }

    if (issues.isNotEmpty) {
      return ValidationResult(
        isValid: false,
        encoderType: VisionEncoderType.gemma3SigLIP,
        message: 'Gemma 3 compatibility issues: ${issues.join(', ')}',
        suggestions: suggestions,
      );
    }

    return const ValidationResult(
      isValid: true,
      encoderType: VisionEncoderType.gemma3SigLIP,
      message: 'Image is compatible with Gemma 3 SigLIP encoder',
      suggestions: [],
    );
  }

  /// Validates general vision encoder compatibility
  static ValidationResult _validateGeneralCompatibility(Uint8List imageBytes) {
    // General requirements that work across most vision encoders
    if (imageBytes.length < 10 * 1024) {
      // < 10KB
      return const ValidationResult(
        isValid: false,
        encoderType: VisionEncoderType.general,
        message: 'Image file too small, may be corrupted',
        suggestions: ['Check image integrity and try a different image'],
      );
    }

    return const ValidationResult(
      isValid: true,
      encoderType: VisionEncoderType.general,
      message: 'Image meets general vision encoder requirements',
      suggestions: [],
    );
  }

  /// Checks for corruption indicators in image bytes
  static bool _hasCorruptionIndicators(Uint8List imageBytes) {
    // Check for repeating patterns that might indicate corruption
    if (imageBytes.length < 100) return true; // Too small

    // Check for excessive repetition of specific byte patterns
    final patternCounts = <String, int>{};
    for (int i = 0; i < imageBytes.length - 3; i++) {
      final pattern =
          '${imageBytes[i]}-${imageBytes[i + 1]}-${imageBytes[i + 2]}';
      patternCounts[pattern] = (patternCounts[pattern] ?? 0) + 1;
    }

    // If any 3-byte pattern appears too frequently, it might be corrupted
    for (final count in patternCounts.values) {
      if (count > imageBytes.length * 0.01) {
        // More than 1% of the image
        return true;
      }
    }

    return false;
  }

  /// Checks if image has proper encoding for vision processing
  static bool _hasProperEncoding(Uint8List imageBytes) {
    // Check for PNG signature (preferred format)
    if (imageBytes.length >= 8 &&
        imageBytes[0] == 0x89 &&
        imageBytes[1] == 0x50 &&
        imageBytes[2] == 0x4E &&
        imageBytes[3] == 0x47) {
      return true;
    }

    // Check for JPEG signature (acceptable)
    if (imageBytes.length >= 3 &&
        imageBytes[0] == 0xFF &&
        imageBytes[1] == 0xD8 &&
        imageBytes[2] == 0xFF) {
      return true;
    }

    return false;
  }
}

/// Vision encoder types with their specifications
enum VisionEncoderType { gemma3SigLIP, general }

/// Base class for vision encoder specifications
abstract class VisionSpecs {
  final VisionEncoderType encoderType;
  final List<String> supportedFormats;
  final int maxFileSize;
  final int minFileSize;
  final int maxWidth;
  final int maxHeight;
  final int minWidth;
  final int minHeight;
  final int targetWidth;
  final int targetHeight;

  const VisionSpecs({
    required this.encoderType,
    required this.supportedFormats,
    required this.maxFileSize,
    required this.minFileSize,
    required this.maxWidth,
    required this.maxHeight,
    required this.minWidth,
    required this.minHeight,
    required this.targetWidth,
    required this.targetHeight,
  });

  double get maxFileSizeMB => maxFileSize / (1024 * 1024);
}

/// Gemma 3 SigLIP vision encoder specifications
class Gemma3Specs extends VisionSpecs {
  const Gemma3Specs()
    : super(
        encoderType: VisionEncoderType.gemma3SigLIP,
        supportedFormats: const ['png', 'jpg', 'jpeg'],
        maxFileSize: 5 * 1024 * 1024, // 5MB
        minFileSize: 10 * 1024, // 10KB
        maxWidth: 1024,
        maxHeight: 1024,
        minWidth: 224,
        minHeight: 224,
        targetWidth: 896,
        targetHeight: 896,
      );
}

/// General vision encoder specifications
class GeneralVisionSpecs extends VisionSpecs {
  const GeneralVisionSpecs()
    : super(
        encoderType: VisionEncoderType.general,
        supportedFormats: const ['png', 'jpg', 'jpeg', 'webp'],
        maxFileSize: 10 * 1024 * 1024, // 10MB
        minFileSize: 5 * 1024, // 5KB
        maxWidth: 2048,
        maxHeight: 2048,
        minWidth: 112,
        minHeight: 112,
        targetWidth: 512,
        targetHeight: 512,
      );
}

/// Result of image validation
class ValidationResult {
  final bool isValid;
  final VisionEncoderType encoderType;
  final String message;
  final List<String> suggestions;

  const ValidationResult({
    required this.isValid,
    required this.encoderType,
    required this.message,
    required this.suggestions,
  });

  @override
  String toString() {
    return 'ValidationResult(isValid: $isValid, encoder: ${encoderType.name}, '
        'message: $message, suggestions: $suggestions)';
  }
}

/// Estimated image dimensions
class EstimatedDimensions {
  final int width;
  final int height;

  const EstimatedDimensions(this.width, this.height);
}

/// Exception thrown when validation fails
class VisionEncoderValidationException implements Exception {
  final String message;
  final Exception? cause;

  const VisionEncoderValidationException(this.message, [this.cause]);

  @override
  String toString() => 'VisionEncoderValidationException: $message';
}
