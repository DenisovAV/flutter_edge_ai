// StopTokenFilter is deprecated but still exported; its behaviour is pinned here.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/chat.dart';
import 'package:flutter_edge_ai/core/extensions.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_response.dart';

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

  group('StopTokenFilter', () {
    test('passes through when fileType is task', () async {
      final input = Stream.fromIterable([
        const TextResponse('Hello'),
        const TextResponse('<end_of_turn>'),
        const TextResponse('More text'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.task,
      ).toList();

      expect(results.length, equals(3));
      expect((results[0] as TextResponse).token, equals('Hello'));
      expect((results[1] as TextResponse).token, equals('<end_of_turn>'));
      expect((results[2] as TextResponse).token, equals('More text'));
    });

    test('passes through when fileType is binary', () async {
      final input = Stream.fromIterable([
        const TextResponse('Hello'),
        const TextResponse('<end_of_turn>'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.binary,
      ).toList();

      expect(results.length, equals(2));
    });

    // Note: On macOS test runner, litertlm filter passes through
    // because defaultTargetPlatform != iOS.
    // The stop token detection logic is tested via direct stream manipulation below.
    test('litertlm passes through on non-iOS (test runner is macOS)', () async {
      final input = Stream.fromIterable([
        const TextResponse('Hello'),
        const TextResponse('<end_of_turn>'),
        const TextResponse('More'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.litertlm,
      ).toList();

      // On macOS test runner: passes through (not iOS)
      expect(results.length, equals(3));
    });

    test('litertlm on iOS stops at end_of_turn token', () async {
      // Override platform for test
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      final input = Stream.fromIterable([
        const TextResponse('Hello '),
        const TextResponse('world'),
        const TextResponse('<end_of_turn>'),
        const TextResponse('Should not appear'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.litertlm,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(text, equals('Hello world'));
    });

    test('litertlm on iOS handles partial stop token across chunks', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      // Stop token split across multiple chunks: "<end" + "_of_turn>"
      final input = Stream.fromIterable([
        const TextResponse('Hi'),
        const TextResponse('<end'),
        const TextResponse('_of_turn>'),
        const TextResponse('After stop'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.litertlm,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(text, equals('Hi'));
    });

    test('litertlm on iOS emits partial buffer if not a stop token', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      // Starts like stop token but doesn't complete
      final input = Stream.fromIterable([
        const TextResponse('Text'),
        const TextResponse('<end_other>'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.litertlm,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(text, equals('Text<end_other>'));
    });

    test('litertlm on iOS handles stop token embedded in text', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      final input = Stream.fromIterable([
        const TextResponse('Answer is 42<end_of_turn>extra'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.litertlm,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      expect(text, equals('Answer is 42'));
    });

    test('litertlm on iOS handles multiple end_of_turn tokens', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      final input = Stream.fromIterable([
        const TextResponse('First<end_of_turn>Second<end_of_turn>'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.litertlm,
      ).toList();

      final text = results.whereType<TextResponse>().map((r) => r.token).join();

      // Should stop at first <end_of_turn>
      expect(text, equals('First'));
    });

    test('litertlm on iOS preserves non-text responses', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      final input = Stream.fromIterable([
        const ThinkingResponse('thinking...'),
        const TextResponse('Hello'),
        const TextResponse('<end_of_turn>'),
      ]);

      final results = await StopTokenFilter.filterStopTokens(
        input,
        fileType: ModelFileType.litertlm,
      ).toList();

      expect(results[0], isA<ThinkingResponse>());
      final textResults = results.whereType<TextResponse>().toList();
      final text = textResults.map((r) => r.token).join();
      expect(text, equals('Hello'));
    });
  });
}
