// Gemma 4 answers in text after a tool's result when thinking is on.
//
// litert-community's Gemma 4 E2B and E4B files embed an older chat template
// that opens no thought after a tool response and prefills `<|tool_response>`
// twice; on it this reply (greedy, the three tools below) is empty.
// litertlm_dart renders LiteRT-LM's canonical template for those files
// instead (lib/src/runtime/gemma4_chat_template.dart), and the reply is text.
//
// Run by hand with a Gemma 4 E2B or E4B bundle:
//
//   LITERTLM_MODEL=/path/to/gemma-4-E2B-it.litertlm dart test test/gemma4_tool_answer_test.dart
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

void main() {
  final model = Platform.environment['LITERTLM_MODEL'];
  final backend = switch (Platform.environment['LITERTLM_BACKEND'] ?? 'cpu') {
    'gpu' => const Backend.gpu(),
    _ => const Backend.cpu(),
  };
  final isGemma4 = model != null && model.toLowerCase().contains('gemma-4-e');

  test(
    'Gemma 4 with thinking answers after an action tool returns',
    () async {
      final engine = await Engine.create(
        EngineConfig(modelPath: model!, backend: backend),
      );
      addTearDown(engine.close);
      final shown = <Map<String, Object?>>[];
      final conversation = await engine.createConversation(
        ConversationConfig(
          // The example app's tools (tool_calling_test.dart): with
          // show_alert alone the model thinks the request done and answers
          // nothing on either template.
          tools: [
            Tool(
              name: 'change_app_title',
              description: 'Changes the title of the app',
              parameters: {
                'type': 'object',
                'properties': {
                  'title': {
                    'type': 'string',
                    'description': 'The new title for the app',
                  },
                },
                'required': ['title'],
              },
              execute: (_) => {'status': 'success'},
            ),
            Tool(
              name: 'change_background_color',
              description: 'Changes the background color of the app',
              parameters: {
                'type': 'object',
                'properties': {
                  'color': {
                    'type': 'string',
                    'description': 'The color to change to',
                    'enum': [
                      'red',
                      'green',
                      'blue',
                      'yellow',
                      'purple',
                      'orange',
                    ],
                  },
                },
                'required': ['color'],
              },
              execute: (_) => {'status': 'success'},
            ),
            Tool(
              name: 'show_alert',
              description: 'Shows an alert dialog to the user',
              parameters: {
                'type': 'object',
                'properties': {
                  'title': {
                    'type': 'string',
                    'description': 'The title of the alert',
                  },
                  'message': {
                    'type': 'string',
                    'description': 'The message to display',
                  },
                },
                'required': ['title', 'message'],
              },
              execute: (arguments) {
                shown.add(arguments);
                return {'status': 'success'};
              },
            ),
          ],
          // Greedy, so the reply is the same on every run.
          samplerConfig: SamplerConfig(topK: 1, topP: 1, temperature: 1),
          thinkingConfig: ThinkingConfig(enableThinking: true),
        ),
      );
      addTearDown(conversation.close);
      final text = StringBuffer();
      await for (final piece in conversation.sendMessageStream(
        Message.user('Show an alert with title "Test" and message "Hello"'),
      )) {
        text.write(piece.text);
      }
      expect(shown, [
        {'title': 'Test', 'message': 'Hello'},
      ]);
      expect('$text'.trim(), isNotEmpty);
    },
    tags: ['model'],
    timeout: const Timeout(Duration(minutes: 5)),
    skip: isGemma4
        ? false
        : 'set LITERTLM_MODEL to a Gemma 4 E2B or E4B .litertlm file',
  );
}
