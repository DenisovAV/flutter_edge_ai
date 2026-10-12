import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/src/extensions.dart';
import 'package:flutter_edge_ai/src/message.dart';
import 'package:flutter_edge_ai/src/model.dart';

void main() {
  group('ModelFileType.litertlm - transformToChatPrompt', () {
    test('on non-iOS (macOS test runner) returns raw text like task', () {
      // Test runner is macOS — not iOS, so litertlm should behave like task
      const message = Message(text: 'Hello!', isUser: true);
      final result = message.transformToChatPrompt(
        type: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      );

      // On non-iOS: raw text (like task), no turn markers
      expect(result, equals('Hello!'));
    });

    test('on non-iOS tool response is formatted', () {
      const message = Message(
        text: 'Tool result here',
        isUser: false,
        type: MessageType.toolResponse,
        toolName: 'get_weather',
      );
      final result = message.transformToChatPrompt(
        type: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      );

      // On non-iOS: tool response formatted but no turn markers
      expect(result, contains('<tool_response>'));
      expect(result, contains('get_weather'));
    });

    // The regression this pins: from 0.13.0 the iOS branch wrapped .litertlm by
    // hand, and since 0.14.0 that text reached the LiteRT-LM Conversation API,
    // which templates it again — the markers arrived as message content. On
    // Gemma 4, "repeat my message word for word" came back as just `model`.
    // Every ModelType, because each had its own hand-written wrapper there.
    for (final type in ModelType.values) {
      test(
        'on iOS returns raw text for ${type.name} — no hand-written turn markers',
        () {
          debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);

          const message = Message(text: 'Hello!', isUser: true);
          final result = message.transformToChatPrompt(
            type: type,
            fileType: ModelFileType.litertlm,
          );

          expect(result, equals('Hello!'));
        },
      );
    }

    test('task fileType always returns raw text regardless of platform', () {
      const message = Message(text: 'Hello!', isUser: true);
      final result = message.transformToChatPrompt(
        type: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      );

      expect(result, equals('Hello!'));
    });

    test('binary fileType always applies manual formatting', () {
      const message = Message(text: 'Hello!', isUser: true);
      final result = message.transformToChatPrompt(
        type: ModelType.gemmaIt,
        fileType: ModelFileType.binary,
      );

      // Binary: always has turn markers
      expect(result, contains('<start_of_turn>'));
      expect(result, contains('<end_of_turn>'));
      expect(result, contains('Hello!'));
    });
  });

  group('ModelFileType.litertlm - cleanResponse', () {
    test('on non-iOS just trims', () {
      final result = ModelThinkingFilter.cleanResponse(
        '  Hello world  <end_of_turn>  ',
        enableThinking: false,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      );

      // On non-iOS: just trim (LiteRT-LM SDK handles cleanup)
      expect(result, equals('Hello world  <end_of_turn>'));
    });

    test('on iOS just trims too — nothing is stripped', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final result = ModelThinkingFilter.cleanResponse(
        '  Hello world  <end_of_turn>  ',
        enableThinking: false,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      );

      expect(result, equals('Hello world  <end_of_turn>'));
    });

    test('task fileType just trims', () {
      final result = ModelThinkingFilter.cleanResponse(
        '  Hello world  ',
        enableThinking: false,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      );

      expect(result, equals('Hello world'));
    });

    test('binary fileType with gemmaIt applies model-specific cleaning', () {
      final result = ModelThinkingFilter.cleanResponse(
        'Hello world<end_of_turn>',
        enableThinking: false,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.binary,
      );

      // Binary + gemmaIt: trailing <end_of_turn> is stripped
      expect(result, equals('Hello world'));
    });
  });
}
