// A text LoRA on a real model, through the public API (opt-in):
//
//   FUNCTIONGEMMA_LORA_LITERTLM  FunctionGemma 270M exported with LoRA input
//                                signatures (LiteRT-LM's LoRA Colab, step 3)
//   FUNCTIONGEMMA_TASK_LORA      the Colab's task adapter (.tflite)
//   FUNCTIONGEMMA_LORA_TOOLS     the Colab's tools.json
//   LITERTLM_LORA_BACKEND        cpu (default) or gpu
//
// The adapter turns the Colab's first held-out prompt into the fine-tuned
// tool call; the base model, a conversation without an adapter on the same
// engine before and after the LoRA conversation, does not. Needs a
// libLiteRtLm with patch_c_api.sh section 33.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

String? _env(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty && File(value).existsSync()
      ? value
      : null;
}

void main() {
  final model = _env('FUNCTIONGEMMA_LORA_LITERTLM');
  final adapter = _env('FUNCTIONGEMMA_TASK_LORA');
  final toolsJson = _env('FUNCTIONGEMMA_LORA_TOOLS');
  final gpu = Platform.environment['LITERTLM_LORA_BACKEND'] == 'gpu';
  final skip = model == null || adapter == null || toolsJson == null
      ? 'FUNCTIONGEMMA_LORA_LITERTLM, FUNCTIONGEMMA_TASK_LORA and '
            'FUNCTIONGEMMA_LORA_TOOLS are not set'
      : null;

  test(
    'the task adapter gives the fine-tuned tool call; the base model, '
    'before and after it on the same engine, does not '
    '(${gpu ? 'gpu' : 'cpu'})',
    () async {
      final tools = [
        for (final t
            in (jsonDecode(File(toolsJson!).readAsStringSync()) as List)
                .cast<Map<String, Object?>>())
          Tool(
            name: t['name']! as String,
            description: (t['description'] ?? '') as String,
            parameters: (t['parameters'] ?? const {}) as Map<String, Object?>,
          ),
      ];
      final engine = await Engine.create(
        EngineConfig(
          modelPath: model!,
          backend: gpu ? const Backend.gpu() : const Backend.cpu(),
          maxNumTokens: 1024,
        ),
      );
      addTearDown(engine.close);

      Future<ToolCall?> ask(LoraConfig? lora) async {
        final conversation = await engine.createConversation(
          ConversationConfig(
            tools: tools,
            automaticToolCalling: false,
            maxOutputTokens: 64,
            loraConfig: lora,
          ),
        );
        try {
          final reply = await conversation.sendMessage(
            Message.user('Turn on the living room lights'),
          );
          return reply.toolCalls.isEmpty ? null : reply.toolCalls.first;
        } finally {
          await conversation.close();
        }
      }

      bool fineTuned(ToolCall? call) =>
          call != null &&
          call.name == 'set_device_state' &&
          call.arguments['device_id'] == 'light.living_room' &&
          call.arguments['state'] == 'on';

      final before = await ask(null);
      final tuned = await ask(LoraConfig(loraPath: adapter));
      final after = await ask(null);
      expect(fineTuned(tuned), isTrue, reason: 'with the adapter: $tuned');
      expect(fineTuned(before), isFalse, reason: 'base, before: $before');
      expect(fineTuned(after), isFalse, reason: 'base, after: $after');
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
