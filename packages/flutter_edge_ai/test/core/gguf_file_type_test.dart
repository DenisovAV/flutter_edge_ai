// ModelFileType.gguf: llama.cpp applies the chat template stored in the
// file, so core never wraps a message in manual turn markers — the posture of
// .onnx and .litertlm. The reply is cleaned as a .bin's is: a trailing
// end-of-turn marker a template renders as text is stripped.
import 'package:flutter_edge_ai/src/extensions.dart';
import 'package:flutter_edge_ai/src/message.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelFileType.gguf - transformToChatPrompt', () {
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
          fileType: ModelFileType.gguf,
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
        fileType: ModelFileType.gguf,
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
          fileType: ModelFileType.gguf,
        );
        expect(prompt, contains('<tool_response>'));
        expect(prompt, contains('Tool Name: add'));
        expect(prompt, isNot(contains('<start_of_turn>')));
      },
    );
  });

  group('ModelFileType.gguf - cleanResponse', () {
    test('trims whitespace', () {
      final cleaned = ModelThinkingFilter.cleanResponse(
        '  Answer text  \n',
        enableThinking: false,
        modelType: ModelType.general,
        fileType: ModelFileType.gguf,
      );
      expect(cleaned, 'Answer text');
    });

    test('strips a trailing end-of-turn marker, as for .bin', () {
      final gemma = ModelThinkingFilter.cleanResponse(
        'Answer<end_of_turn>\n',
        enableThinking: false,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.gguf,
      );
      expect(gemma, 'Answer');

      final qwen = ModelThinkingFilter.cleanResponse(
        'Answer<|im_end|>',
        enableThinking: false,
        modelType: ModelType.qwen3,
        fileType: ModelFileType.gguf,
      );
      expect(qwen, 'Answer');
    });

    test('keeps a marker in the middle of the text', () {
      final cleaned = ModelThinkingFilter.cleanResponse(
        'keep <end_of_turn> literal',
        enableThinking: false,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.gguf,
      );
      expect(cleaned, 'keep <end_of_turn> literal');
    });
  });
}
