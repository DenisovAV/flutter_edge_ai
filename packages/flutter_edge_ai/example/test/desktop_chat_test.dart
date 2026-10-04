// Integration test for Desktop LiteRT-LM chat
// Run with: cd example && flutter test test/desktop_chat_test.dart -d macos

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/model_response.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Desktop LiteRT-LM Chat Test', () {
    late InferenceModel model;
    late InferenceChat chat;

    setUpAll(() async {
      debugPrint('=== Setting up Desktop Chat Test ===');

      // Initialize FlutterEdgeAi
      await FlutterEdgeAi.initialize();
      debugPrint('FlutterEdgeAi initialized');

      // Check if model is installed
      final hasModel = FlutterEdgeAi.hasActiveModel();
      debugPrint('Has active model: $hasModel');

      if (!hasModel) {
        fail(
          'No active model set. Install gemma-3n-E2B-it-int4 first via the example app.',
        );
      }

      // Create model with minimal config - NO audio/image support to test pure text
      model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
        supportAudio: false,
        supportImage: false,
      );
      debugPrint('Model created: ${model.runtimeType}');

      // Create chat
      chat = await model.createChat();
      debugPrint('Chat created: ${chat.runtimeType}');
    });

    tearDownAll(() async {
      debugPrint('=== Tearing down ===');
      await model.close();
    });

    test('Simple text chat should work', () async {
      debugPrint('\n=== Test: Simple text chat ===');

      // Add a simple query
      const query = 'Hi';
      debugPrint('Sending query: "$query"');

      await chat.addQueryChunk(const Message(text: query, isUser: true));
      debugPrint('Query added to chat');

      // Get response
      debugPrint('Getting response...');
      final response = await chat.generateChatResponse();

      String responseText = '';
      if (response is TextResponse) {
        responseText = response.token;
      }

      debugPrint('Response received: "${responseText.take(100)}"');
      debugPrint('Response length: ${responseText.length}');

      expect(responseText, isNotEmpty);
      expect(responseText.length, greaterThan(1));
    });

    test('Streaming response should work', () async {
      debugPrint('\n=== Test: Streaming response ===');

      await chat.addQueryChunk(
        const Message(text: 'Count from 1 to 3', isUser: true),
      );

      final chunks = <String>[];
      await for (final response in chat.generateChatResponseAsync()) {
        if (response is TextResponse) {
          chunks.add(response.token);
          if (chunks.length <= 10) {
            debugPrint('Chunk ${chunks.length}: "${response.token}"');
          }
        }
      }

      final fullResponse = chunks.join();
      debugPrint('Total chunks: ${chunks.length}');
      debugPrint('Full response: "${fullResponse.take(100)}"');

      expect(chunks, isNotEmpty);
      expect(fullResponse, isNotEmpty);
    });
  });
}

extension StringTake on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
