import 'package:flutter_edge_ai/core/extensions.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelFileType.builtIn - transformToChatPrompt', () {
    test('user message returns raw content (native side owns templates)', () {
      const msg = Message(text: 'Hello world', isUser: true);
      final prompt = msg.transformToChatPrompt(
        type: ModelType.general,
        fileType: ModelFileType.builtIn,
      );
      expect(prompt, 'Hello world'); // no <start_of_turn> markers
    });

    test('gemmaIt model type still returns raw for builtIn', () {
      const msg = Message(text: 'Hi', isUser: true);
      final prompt = msg.transformToChatPrompt(
        type: ModelType.gemmaIt,
        fileType: ModelFileType.builtIn,
      );
      expect(prompt, isNot(contains('<start_of_turn>')));
    });
  });

  group('ModelFileType.builtIn - cleanResponse', () {
    test('trim-only cleaning', () {
      final cleaned = ModelThinkingFilter.cleanResponse(
        '  Answer text  \n',
        enableThinking: false,
        modelType: ModelType.general,
        fileType: ModelFileType.builtIn,
      );
      expect(cleaned, 'Answer text');
    });

    test('does not strip model-specific tags mid-text', () {
      final cleaned = ModelThinkingFilter.cleanResponse(
        'keep <end_of_turn> literal',
        enableThinking: false,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.builtIn,
      );
      expect(cleaned, 'keep <end_of_turn> literal');
    });
  });
}
