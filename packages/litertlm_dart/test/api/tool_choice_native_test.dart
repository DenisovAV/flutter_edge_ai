// ToolChoice on real models (opt-in): refused by name where LiteRT-LM drops
// it, applied where the model family applies it.
//
//   GEMMA4_E2B_LITERTLM  Gemma 4 E2B (.litertlm)
//   QWEN3_LITERTLM       Qwen3 0.6B (.litertlm), a family that drops it
//
// Prints what each run saw, for the record.
@TestOn('vm')
library;

import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

String? _file(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty && File(value).existsSync()
      ? value
      : null;
}

final _weather = Tool(
  name: 'get_weather',
  description: 'Gets the current weather of a city.',
  parameters: {
    'type': 'object',
    'properties': {
      'city': {'type': 'string', 'description': 'The city.'},
    },
    'required': ['city'],
  },
);

void main() {
  final gemma4 = _file('GEMMA4_E2B_LITERTLM');
  final qwen3 = _file('QWEN3_LITERTLM');

  Future<Conversation> conversationOn(Engine engine) =>
      engine.createConversation(
        ConversationConfig(tools: [_weather], automaticToolCalling: false),
      );

  test(
    'Qwen3: a tool choice other than auto is refused by name; auto goes',
    skip: qwen3 == null ? 'QWEN3_LITERTLM' : null,
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final engine = await Engine.create(
        EngineConfig(modelPath: qwen3!, maxNumTokens: 1024),
      );
      try {
        final conversation = await conversationOn(engine);
        Object? refusal;
        try {
          await conversation.sendMessage(
            Message.user('Hello.'),
            toolChoice: ToolChoice.required,
          );
        } catch (e) {
          refusal = e;
        }
        print('[tool choice qwen3] required: $refusal');
        expect(refusal, isA<UnsupportedError>());
        expect('$refusal', contains('drops it'));
        final reply = await conversation.sendMessage(
          Message.user('Say hello in one word.'),
          toolChoice: ToolChoice.auto,
        );
        print('[tool choice qwen3] auto: ${reply.text.trim()}');
        await conversation.close();
      } finally {
        await engine.close();
      }
    },
  );

  test(
    'Gemma 4: required calls the tool, none answers in text',
    skip: gemma4 == null ? 'GEMMA4_E2B_LITERTLM' : null,
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final engine = await Engine.create(
        EngineConfig(modelPath: gemma4!, maxNumTokens: 2048),
      );
      try {
        var conversation = await conversationOn(engine);
        final called = await conversation.sendMessage(
          Message.user('Tell me a short joke.'),
          toolChoice: ToolChoice.required,
        );
        print(
          '[tool choice gemma4] required: calls ${called.toolCalls}, '
          'text "${called.text.trim()}"',
        );
        expect(called.toolCalls, isNotEmpty);
        await conversation.close();
        conversation = await conversationOn(engine);
        final text = await conversation.sendMessage(
          Message.user('What is the weather in Paris?'),
          toolChoice: ToolChoice.none,
        );
        print(
          '[tool choice gemma4] none: calls ${text.toolCalls}, '
          'text "${text.text.trim()}"',
        );
        expect(text.toolCalls, isEmpty);
        await conversation.close();
      } finally {
        await engine.close();
      }
    },
  );
}
