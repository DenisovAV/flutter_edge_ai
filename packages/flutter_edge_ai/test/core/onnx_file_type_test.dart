// Hardened plan Phase 3, Task 3: ModelFileType.onnx routes through the
// SDK-owns-templates (raw) path, same posture as .litertlm on non-iOS and
// .builtIn — ORT-GenAI's OgaTokenizerApplyChatTemplate owns the chat
// template, so core must never inject manual <start_of_turn>/<|im_end|>
// markers for onnx. Mirrors builtin_file_type_test.dart.
import 'package:flutter_edge_ai/core/extensions.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelFileType.onnx - transformToChatPrompt', () {
    for (final type in [
      ModelType.general,
      ModelType.gemmaIt,
      ModelType.gemma4,
      ModelType.qwen3,
      ModelType.phi,
    ]) {
      test('$type: user message returns raw content, no turn markers', () {
        const msg = Message(text: 'Hello world', isUser: true);
        final prompt = msg.transformToChatPrompt(
          type: type,
          fileType: ModelFileType.onnx,
        );
        expect(prompt, 'Hello world');
        expect(prompt, isNot(contains('<start_of_turn>')));
        expect(prompt, isNot(contains('<|im_start|>')));
        expect(prompt, isNot(contains('<|user|>')));
      });
    }

    test('systemInfo messages are dropped (not sent to the model)', () {
      const msg = Message(text: 'ignored', type: MessageType.systemInfo);
      final prompt = msg.transformToChatPrompt(
        type: ModelType.gemmaIt,
        fileType: ModelFileType.onnx,
      );
      expect(prompt, '');
    });

    test(
      'tool response content still gets the shared tool-response wrapper',
      () {
        const msg = Message(
          text: '42',
          type: MessageType.toolResponse,
          toolName: 'add',
        );
        final prompt = msg.transformToChatPrompt(
          type: ModelType.gemma4,
          fileType: ModelFileType.onnx,
        );
        expect(prompt, contains('<tool_response>'));
        expect(prompt, contains('Tool Name: add'));
        expect(prompt, isNot(contains('<start_of_turn>')));
      },
    );
  });

  group('ModelFileType.onnx - cleanResponse', () {
    test('trim-only cleaning', () {
      final cleaned = ModelThinkingFilter.cleanResponse(
        '  Answer text  \n',
        enableThinking: false,
        modelType: ModelType.general,
        fileType: ModelFileType.onnx,
      );
      expect(cleaned, 'Answer text');
    });

    test(
      'does not strip <end_of_turn>/<|im_end|> mid-text (SDK never emits them)',
      () {
        final gemma = ModelThinkingFilter.cleanResponse(
          'keep <end_of_turn> literal',
          enableThinking: false,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.onnx,
        );
        expect(gemma, 'keep <end_of_turn> literal');

        final qwen = ModelThinkingFilter.cleanResponse(
          'keep <|im_end|> literal',
          enableThinking: false,
          modelType: ModelType.qwen3,
          fileType: ModelFileType.onnx,
        );
        expect(qwen, 'keep <|im_end|> literal');
      },
    );
  });
}
