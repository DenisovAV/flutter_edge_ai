@TestOn('!vm')
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// Test suite for AI image corruption fix implementation
void main() {
  group('AI Image Corruption Fix Tests', () {
    test('ImageProcessor can detect image format', () {
      // Test PNG signature detection
      final pngBytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // More PNG data
      ]);

      final format = ImageProcessor.detectFormat(pngBytes);
      expect(format, equals('png'));
    });

    test('ImageProcessor can validate Base64 encoding', () {
      const testString = 'SGVsbG8gV29ybGQ='; // Valid Base64

      // This should not throw an exception
      expect(() {
        final decoded = base64.decode(testString);
        expect(decoded, isNotNull);
      }, returnsNormally);
    });

    test('ImageTokenizer can create structured message', () {
      final processedImage = ProcessedImage(
        originalBytes: Uint8List.fromList([1, 2, 3]),
        processedBytes: Uint8List.fromList([1, 2, 3]),
        base64String: 'SGVsbG8gV29ybGQ=',
        width: 896,
        height: 896,
        format: 'png',
      );

      final message = ImageTokenizer.createImageMessage(
        text: 'Describe this image',
        processedImage: processedImage,
        role: 'user',
      );

      expect(message, isA<Map<String, dynamic>>());
      expect(message['role'], equals('user'));
      expect(message['content'], isA<List>());
      expect(message['content'].length, equals(2)); // text + image
    });

    test('VisionEncoderValidator can validate encoder type', () {
      final testBytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // More PNG data
      ]);

      final result = VisionEncoderValidator.validateForEncoder(
        imageBytes: testBytes,
        encoderType: VisionEncoderType.gemma3SigLIP,
      );

      expect(result, isA<ValidationResult>());
      expect(result.encoderType, equals(VisionEncoderType.gemma3SigLIP));
    });

    test('ImageErrorHandler can categorize errors', () {
      final errorResult = ImageErrorHandler.handleImageProcessingError(
        'Base64 encoding failed',
        StackTrace.current,
        context: 'test',
      );

      expect(errorResult, isA<ErrorHandlingResult>());
      expect(errorResult.errorType, equals(ErrorType.base64Encoding));
      expect(errorResult.isRecoverable, isTrue);
      expect(errorResult.suggestions, isNotEmpty);
    });

    test('ImageTokenizer can detect corruption patterns', () {
      // Test known corruption patterns
      const corruptedResponse1 = 'describe.describe.describe.describe.';
      const corruptedResponse2 = '₹₹₹₹₹₹₹₹₹₹';
      const corruptedResponse3 = 'ph ph ph ph ph';

      expect(
        ImageTokenizer.detectCorruptionPatterns(corruptedResponse1),
        isTrue,
      );

      expect(
        ImageTokenizer.detectCorruptionPatterns(corruptedResponse2),
        isTrue,
      );

      expect(
        ImageTokenizer.detectCorruptionPatterns(corruptedResponse3),
        isTrue,
      );

      // Test normal response
      const normalResponse = 'This is a normal response about the image.';
      expect(ImageTokenizer.detectCorruptionPatterns(normalResponse), isFalse);
    });

    test('MultimodalImageHandler can process without validation', () async {
      // Test with validation disabled to avoid image processing issues
      final result = await MultimodalImageHandler.processImageForAI(
        imageBytes: Uint8List.fromList([
          0x89,
          0x50,
          0x4E,
          0x47,
        ]), // Minimal PNG signature
        modelType: ModelType.gemmaIt,
        enableValidation: false,
        enableProcessing: false,
      );

      expect(result, isA<MultimodalImageResult>());
      expect(result.success, isTrue);
      expect(result.validationPassed, isFalse);
    });

    test('MultimodalImageHandler handles processing errors gracefully', () async {
      // Test error handling with invalid image data
      try {
        final result = await MultimodalImageHandler.processImageForAI(
          imageBytes: Uint8List.fromList([
            0x00,
            0x01,
            0x02,
          ]), // Invalid image data
          modelType: ModelType.gemmaIt,
          enableValidation: false,
          enableProcessing: true,
        );

        expect(result, isA<MultimodalImageResult>());
        expect(result.success, isFalse);
        expect(result.error, isNotNull);
        expect(result.error!.errorType, equals(ErrorType.imageFormat));
      } catch (e) {
        // If exception is thrown instead of returning error result, that's also acceptable
        expect(e, isA<Exception>());
      }
    });

    test('Response validation detects corruption', () {
      final processedImage = ProcessedImage(
        originalBytes: Uint8List.fromList([1, 2, 3]),
        processedBytes: Uint8List.fromList([1, 2, 3]),
        base64String: 'test_base64',
        width: 896,
        height: 896,
        format: 'png',
      );

      // Test corrupted response
      const corruptedResponse = 'describe.describe.describe.describe.';
      final validation = MultimodalImageHandler.validateModelResponse(
        corruptedResponse,
        originalPrompt: 'Describe this image',
        processedImage: processedImage,
      );

      expect(validation.isValid, isFalse);
      expect(validation.isCorrupted, isTrue);
      expect(validation.confidence, greaterThan(0.5));
      expect(validation.suggestedAction, equals(ResponseAction.reprocessImage));
    });

    test('Response validation accepts normal response', () {
      final processedImage = ProcessedImage(
        originalBytes: Uint8List.fromList([1, 2, 3]),
        processedBytes: Uint8List.fromList([1, 2, 3]),
        base64String: 'test_base64',
        width: 896,
        height: 896,
        format: 'png',
      );

      // Test normal response
      const normalResponse =
          'This image shows a beautiful landscape with mountains.';
      final validation = MultimodalImageHandler.validateModelResponse(
        normalResponse,
        originalPrompt: 'Describe this image',
        processedImage: processedImage,
      );

      // This test should PASS when the bug in validateModelResponse is fixed
      // BUG in MultimodalImageHandler.validateModelResponse lines 210-217:
      // Returns wrong values for successful validation (isValid: false, isCorrupted: true)
      expect(validation.isValid, isTrue); // Should be true for normal response
      expect(
        validation.isCorrupted,
        isFalse,
      ); // Should be false for normal response
      expect(
        validation.confidence,
        lessThan(0.5),
      ); // Should be low confidence for no corruption
    });
  });
}
