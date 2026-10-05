import 'package:flutter/foundation.dart';
import 'image_processor.dart';
import 'image_tokenizer.dart';
import 'vision_encoder_validator.dart';
import 'utils/gemma_log.dart';

/// Comprehensive error handling and debugging utilities for AI image processing
/// to prevent corruption that causes repeating text patterns in model responses.
class ImageErrorHandler {
  static const int _maxLogSize = 1000; // Maximum characters to log

  /// Handles image processing errors with detailed logging and recovery suggestions
  static ErrorHandlingResult handleImageProcessingError(
    dynamic error,
    StackTrace stackTrace, {
    Uint8List? imageBytes,
    String? context,
  }) {
    gemmaLog('=== IMAGE PROCESSING ERROR ===');
    gemmaLog('Context: $context');
    gemmaLog('Error: $error');
    gemmaLog('StackTrace: $stackTrace');

    if (imageBytes != null) {
      gemmaLog('Image bytes: ${imageBytes.length} bytes');
      _logImageInfo(imageBytes);
    }

    // Categorize the error
    final errorType = _categorizeError(error);
    gemmaLog('Error Type: $errorType');

    // Generate recovery suggestions
    final suggestions = _generateRecoverySuggestions(errorType, imageBytes);

    // Create detailed error message
    final message = _createDetailedErrorMessage(error, errorType, context);

    gemmaLog('Recovery Suggestions: ${suggestions.join(', ')}');
    gemmaLog('================================');

    return ErrorHandlingResult(
      isRecoverable: _isRecoverable(errorType),
      errorType: errorType,
      message: message,
      suggestions: suggestions,
      originalError: error,
      stackTrace: stackTrace,
    );
  }

  /// Handles image tokenization errors with model-specific recovery
  static ErrorHandlingResult handleTokenizationError(
    dynamic error,
    StackTrace stackTrace, {
    required ModelType modelType,
    String? prompt,
    int? expectedImageCount,
  }) {
    gemmaLog('=== IMAGE TOKENIZATION ERROR ===');
    gemmaLog('Model Type: $modelType');
    gemmaLog('Expected Images: $expectedImageCount');
    gemmaLog('Prompt Length: ${prompt?.length ?? 0}');
    if (prompt != null && prompt.length < _maxLogSize) {
      gemmaLog(
        'Prompt Preview: ${_sanitizePromptForLogging(prompt)}',
        level: GemmaLogLevel.verbose,
      );
    }

    final errorType = _categorizeTokenizationError(error, prompt);
    gemmaLog('Tokenization Error Type: $errorType');

    final suggestions = _generateTokenizationRecoverySuggestions(
      errorType,
      modelType,
      expectedImageCount,
    );

    final message = _createTokenizationErrorMessage(
      error,
      errorType,
      modelType,
    );

    gemmaLog('Tokenization Recovery: ${suggestions.join(', ')}');
    gemmaLog('================================');

    return ErrorHandlingResult(
      isRecoverable: _isTokenizationRecoverable(errorType),
      errorType: errorType,
      message: message,
      suggestions: suggestions,
      originalError: error,
      stackTrace: stackTrace,
    );
  }

  /// Handles vision encoder validation failures
  static ErrorHandlingResult handleValidationError(
    ValidationResult validationResult, {
    Uint8List? imageBytes,
    VisionEncoderType? encoderType,
  }) {
    gemmaLog('=== VISION ENCODER VALIDATION ERROR ===');
    gemmaLog('Encoder: ${encoderType?.name ?? 'unknown'}');
    gemmaLog('Validation Result: ${validationResult.isValid}');
    gemmaLog('Message: ${validationResult.message}');

    if (imageBytes != null) {
      _logImageInfo(imageBytes);
    }

    const errorType = ErrorType.visionEncoderValidation;
    final suggestions = <String>[...validationResult.suggestions];

    // Add additional recovery suggestions based on validation failure
    if (!validationResult.isValid) {
      suggestions.addAll(_getValidationRecoverySuggestions(validationResult));
    }

    final message =
        'Vision encoder validation failed: ${validationResult.message}';

    gemmaLog('Validation Recovery: ${suggestions.join(', ')}');
    gemmaLog('======================================');

    return ErrorHandlingResult(
      isRecoverable: true, // Validation errors are usually recoverable
      errorType: errorType,
      message: message,
      suggestions: suggestions,
      originalError: validationResult.message,
    );
  }

  /// Detects and handles model response corruption patterns
  static CorruptionDetectionResult detectResponseCorruption(String response) {
    try {
      gemmaLog('=== DETECTING RESPONSE CORRUPTION ===');
      gemmaLog('Response Length: ${response.length}');
      if (response.length < _maxLogSize) {
        gemmaLog(
          'Response Preview: ${_sanitizeResponseForLogging(response)}',
          level: GemmaLogLevel.verbose,
        );
      }

      // Check for known corruption patterns
      final hasCorruption = ImageTokenizer.detectCorruptionPatterns(response);

      // Analyze response characteristics
      final analysis = _analyzeResponseCharacteristics(response);

      // Determine confidence level
      final confidence = _calculateCorruptionConfidence(
        hasCorruption,
        analysis,
      );

      gemmaLog('Corruption Detected: $hasCorruption');
      gemmaLog('Confidence Level: ${confidence.toStringAsFixed(2)}');
      gemmaLog('Analysis: $analysis');

      return CorruptionDetectionResult(
        isCorrupted: hasCorruption,
        confidence: confidence,
        analysis: analysis,
        suggestedAction: _suggestCorruptionAction(confidence, analysis),
      );
    } catch (e) {
      gemmaLog('Error detecting corruption: $e');
      return CorruptionDetectionResult(
        isCorrupted: false,
        confidence: 0.0,
        analysis: {'error': 'Detection failed: $e'},
        suggestedAction: CorruptionAction.none,
      );
    }
  }

  /// Logs detailed image information for debugging
  static void _logImageInfo(Uint8List imageBytes) {
    try {
      final format = ImageProcessor.detectFormat(imageBytes);
      final sizeInKB = imageBytes.length / 1024;

      gemmaLog('Image Format: $format');
      gemmaLog('Image Size: ${sizeInKB.toStringAsFixed(2)}KB');
      gemmaLog('Image Bytes: ${imageBytes.length}');

      // Log first few bytes for signature analysis
      if (imageBytes.length >= 8) {
        final signature = imageBytes
            .sublist(0, 8)
            .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
            .join(' ');
        gemmaLog('Image Signature: $signature');
      }
    } catch (e) {
      gemmaLog('Error logging image info: $e');
    }
  }

  /// Categorizes image processing errors
  static ErrorType _categorizeError(dynamic error) {
    final errorMessage = error.toString().toLowerCase();

    if (errorMessage.contains('base64')) {
      return ErrorType.base64Encoding;
    }
    if (errorMessage.contains('format') || errorMessage.contains('decode')) {
      return ErrorType.imageFormat;
    }
    if (errorMessage.contains('size') || errorMessage.contains('dimension')) {
      return ErrorType.imageDimensions;
    }
    if (errorMessage.contains('memory') ||
        errorMessage.contains('allocation')) {
      return ErrorType.memoryLimit;
    }
    if (errorMessage.contains('corruption') ||
        errorMessage.contains('corrupt')) {
      return ErrorType.imageCorruption;
    }
    if (errorMessage.contains('network') ||
        errorMessage.contains('transmission')) {
      return ErrorType.networkTransmission;
    }

    return ErrorType.unknown;
  }

  /// Categorizes tokenization errors
  static ErrorType _categorizeTokenizationError(dynamic error, String? prompt) {
    final errorMessage = error.toString().toLowerCase();

    if (errorMessage.contains('token') && errorMessage.contains('image')) {
      return ErrorType.imageTokenMismatch;
    }
    if (errorMessage.contains('0 image tokens')) {
      return ErrorType.imageTokenMismatch;
    }
    if (errorMessage.contains('prompt') &&
        prompt != null &&
        !prompt.contains('image')) {
      return ErrorType.missingImageTokens;
    }

    return ErrorType.tokenization;
  }

  /// Generates recovery suggestions based on error type
  static List<String> _generateRecoverySuggestions(
    ErrorType errorType,
    Uint8List? imageBytes,
  ) {
    final suggestions = <String>[];

    switch (errorType) {
      case ErrorType.base64Encoding:
        suggestions.addAll([
          'Use ImageProcessor.processImage() to get properly encoded Base64',
          'Ensure Base64 string has no whitespace or line breaks',
          'Validate Base64 format before transmission',
        ]);
        break;

      case ErrorType.imageFormat:
        suggestions.addAll([
          'Convert image to PNG format using ImageProcessor',
          'Check image file integrity',
          'Ensure image is not corrupted',
        ]);
        break;

      case ErrorType.imageDimensions:
        suggestions.addAll([
          'Resize image to 896x896 pixels for Gemma 3 compatibility',
          'Use ImageProcessor.processImage() for automatic resizing',
          'Check vision encoder specifications',
        ]);
        break;

      case ErrorType.imageCorruption:
        suggestions.addAll([
          'Re-process image with ImageProcessor to remove corruption',
          'Check image source and re-upload if necessary',
          'Validate image with VisionEncoderValidator before use',
        ]);
        break;

      case ErrorType.imageTokenMismatch:
        suggestions.addAll([
          'Use ImageTokenizer.createImageMessage() for proper tokenization',
          'Ensure image tokens are properly formatted for the model',
          'Check model-specific tokenization requirements',
        ]);
        break;

      default:
        suggestions.addAll([
          'Check image format and size requirements',
          'Use provided utilities for image processing',
          'Enable debug logging for detailed error information',
        ]);
    }

    return suggestions;
  }

  /// Generates tokenization recovery suggestions
  static List<String> _generateTokenizationRecoverySuggestions(
    ErrorType errorType,
    ModelType modelType,
    int? expectedImageCount,
  ) {
    final suggestions = <String>[];

    switch (errorType) {
      case ErrorType.imageTokenMismatch:
        suggestions.addAll([
          'Use ImageTokenizer.createImagePrompt() for ${modelType.name}',
          'Ensure proper image token formatting for the model type',
          'Validate tokens with ImageTokenizer.validateImageTokens()',
        ]);
        break;

      default:
        suggestions.addAll([
          'Check model-specific tokenization requirements',
          'Use structured message format instead of raw tokens',
          'Validate prompt format before sending to model',
        ]);
    }

    return suggestions;
  }

  /// Gets validation-specific recovery suggestions
  static List<String> _getValidationRecoverySuggestions(
    ValidationResult result,
  ) {
    return List<String>.from(result.suggestions);
  }

  /// Analyzes response characteristics for corruption indicators
  static Map<String, dynamic> _analyzeResponseCharacteristics(String response) {
    final analysis = <String, dynamic>{};

    // Length analysis
    analysis['length'] = response.length;
    analysis['isVeryShort'] = response.length < 10;
    analysis['isVeryLong'] = response.length > 10000;

    // Repetition analysis
    final words = response.split(RegExp(r'\s+'));
    analysis['wordCount'] = words.length;

    if (words.isNotEmpty) {
      final uniqueWords = words.toSet().length;
      analysis['uniqueWordRatio'] = uniqueWords / words.length;
      analysis['hasHighRepetition'] = (uniqueWords / words.length) < 0.3;
    }

    // Pattern analysis
    analysis['hasRepeatingDots'] = response.contains(RegExp(r'\.{3,}'));
    analysis['hasRepeatingChars'] = response.contains(RegExp(r'(.)\1{5,}'));
    analysis['hasSingleChars'] = response.contains(
      RegExp(r'\b.\b.*\b.\b.*\b.\b'),
    );

    // Content analysis
    analysis['isMostlySymbols'] = RegExp(
      r'^[^a-zA-Z0-9\s]{10,}',
    ).hasMatch(response);
    analysis['hasDescribeLoop'] = response.contains(
      RegExp(r'describe\.describe\.describe'),
    );

    return analysis;
  }

  /// Calculates confidence level for corruption detection
  static double _calculateCorruptionConfidence(
    bool hasKnownPatterns,
    Map<String, dynamic> analysis,
  ) {
    double confidence = 0.0;

    if (hasKnownPatterns) confidence += 0.5;
    if (analysis['hasHighRepetition'] == true) confidence += 0.3;
    if (analysis['isMostlySymbols'] == true) confidence += 0.2;
    if (analysis['hasDescribeLoop'] == true) confidence += 0.4;
    if (analysis['isVeryShort'] == true) confidence += 0.1;

    return confidence.clamp(0.0, 1.0);
  }

  /// Suggests appropriate action for detected corruption
  static CorruptionAction _suggestCorruptionAction(
    double confidence,
    Map<String, dynamic> analysis,
  ) {
    if (confidence > 0.8) {
      return CorruptionAction.reprocessImage;
    } else if (confidence > 0.5) {
      return CorruptionAction.validateImage;
    } else if (confidence > 0.2) {
      return CorruptionAction.monitorResponse;
    } else {
      return CorruptionAction.none;
    }
  }

  /// Determines if error is recoverable
  static bool _isRecoverable(ErrorType errorType) {
    switch (errorType) {
      case ErrorType.base64Encoding:
      case ErrorType.imageFormat:
      case ErrorType.imageDimensions:
      case ErrorType.imageTokenMismatch:
        return true;
      default:
        return false;
    }
  }

  /// Determines if tokenization error is recoverable
  static bool _isTokenizationRecoverable(ErrorType errorType) {
    return errorType == ErrorType.imageTokenMismatch;
  }

  /// Creates detailed error message
  static String _createDetailedErrorMessage(
    dynamic error,
    ErrorType errorType,
    String? context,
  ) {
    final buffer = StringBuffer();

    if (context != null) {
      buffer.write('$context: ');
    }

    buffer.write('Image processing failed due to ${errorType.name}. ');
    buffer.write('Original error: $error');

    return buffer.toString();
  }

  /// Creates tokenization error message
  static String _createTokenizationErrorMessage(
    dynamic error,
    ErrorType errorType,
    ModelType modelType,
  ) {
    return 'Image tokenization failed for ${modelType.name}: $error';
  }

  /// Sanitizes prompt for safe logging
  static String _sanitizePromptForLogging(String prompt) {
    if (prompt.length > _maxLogSize) {
      return '${prompt.substring(0, _maxLogSize)}...[truncated]';
    }
    // Remove potentially sensitive Base64 data
    return prompt.replaceAll(
      RegExp(r'[A-Za-z0-9+/]{100,}={0,2}'),
      '[IMAGE_DATA]',
    );
  }

  /// Sanitizes response for safe logging
  static String _sanitizeResponseForLogging(String response) {
    if (response.length > _maxLogSize) {
      return '${response.substring(0, _maxLogSize)}...[truncated]';
    }
    return response;
  }
}

/// Types of errors that can occur in image processing
enum ErrorType {
  base64Encoding,
  imageFormat,
  imageDimensions,
  imageCorruption,
  imageTokenMismatch,
  memoryLimit,
  networkTransmission,
  tokenization,
  missingImageTokens,
  visionEncoderValidation,
  unknown,
}

/// Actions to take when corruption is detected
enum CorruptionAction { none, monitorResponse, validateImage, reprocessImage }

/// Result of error handling
class ErrorHandlingResult {
  final bool isRecoverable;
  final ErrorType errorType;
  final String message;
  final List<String> suggestions;
  final dynamic originalError;
  final StackTrace? stackTrace;

  const ErrorHandlingResult({
    required this.isRecoverable,
    required this.errorType,
    required this.message,
    required this.suggestions,
    this.originalError,
    this.stackTrace,
  });

  @override
  String toString() {
    return 'ErrorHandlingResult(type: $errorType, recoverable: $isRecoverable, '
        'message: $message, suggestions: ${suggestions.join(', ')})';
  }
}

/// Result of corruption detection
class CorruptionDetectionResult {
  final bool isCorrupted;
  final double confidence;
  final Map<String, dynamic> analysis;
  final CorruptionAction suggestedAction;

  const CorruptionDetectionResult({
    required this.isCorrupted,
    required this.confidence,
    required this.analysis,
    required this.suggestedAction,
  });

  @override
  String toString() {
    return 'CorruptionDetectionResult(corrupted: $isCorrupted, confidence: ${confidence.toStringAsFixed(2)}, '
        'action: $suggestedAction, analysis: $analysis)';
  }
}
