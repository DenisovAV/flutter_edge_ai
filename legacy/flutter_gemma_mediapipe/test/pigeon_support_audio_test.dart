// Integration test for supportAudio parameter in Pigeon API
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma_mediapipe/pigeon.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformService.createModel supportAudio parameter', () {
    late List<List<Object?>> capturedMessages;

    setUp(() {
      capturedMessages = [];

      // Create a mock that captures messages
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
            'dev.flutter.pigeon.flutter_gemma_mediapipe.PlatformService.createModel',
            (ByteData? message) async {
              if (message != null) {
                // Pigeon uses StandardMessageCodec
                const codec = StandardMessageCodec();
                final decoded = codec.decodeMessage(message);
                if (decoded is List) {
                  capturedMessages.add(decoded);
                }
              }
              // Return success (list with null = success)
              return const StandardMessageCodec().encodeMessage([null]);
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(
            'dev.flutter.pigeon.flutter_gemma_mediapipe.PlatformService.createModel',
            null,
          );
    });

    test('supportAudio=true is sent to native', () async {
      final service = PlatformService();

      await service.createModel(
        maxTokens: 1024,
        modelPath: '/test/model.bin',
        loraRanks: null,
        preferredBackend: null,
        maxNumImages: null,
        supportAudio: true,
      );

      expect(capturedMessages.length, 1);
      final args = capturedMessages.first;

      // Pigeon sends: [maxTokens, modelPath, loraRanks, preferredBackend, maxNumImages, supportAudio]
      // Index: [0, 1, 2, 3, 4, 5]
      expect(args.length, 6, reason: 'createModel has 6 parameters');
      expect(args[0], 1024, reason: 'maxTokens');
      expect(args[1], '/test/model.bin', reason: 'modelPath');
      expect(args[2], isNull, reason: 'loraRanks');
      expect(args[3], isNull, reason: 'preferredBackend');
      expect(args[4], isNull, reason: 'maxNumImages');
      expect(args[5], true, reason: 'supportAudio should be true');
    });

    test('supportAudio=false is sent to native', () async {
      final service = PlatformService();

      await service.createModel(
        maxTokens: 512,
        modelPath: '/test/model2.bin',
        loraRanks: null,
        preferredBackend: null,
        maxNumImages: null,
        supportAudio: false,
      );

      expect(capturedMessages.length, 1);
      final args = capturedMessages.first;

      expect(args.length, 6);
      expect(args[0], 512);
      expect(args[1], '/test/model2.bin');
      expect(args[5], false, reason: 'supportAudio should be false');
    });

    test('supportAudio=null is sent to native', () async {
      final service = PlatformService();

      await service.createModel(
        maxTokens: 256,
        modelPath: '/test/model3.bin',
        loraRanks: null,
        preferredBackend: null,
        maxNumImages: null,
        supportAudio: null,
      );

      expect(capturedMessages.length, 1);
      final args = capturedMessages.first;

      expect(args.length, 6);
      expect(args[5], isNull, reason: 'supportAudio should be null');
    });
  });
}
