// ModelType.gemma4 on the manual path (.bin/.tflite): core writes the turns
// itself, so they must be Gemma 4's own, not Gemma 3's `<start_of_turn>`.
//
// The golden strings are google/gemma-4-E2B-it's `chat_template.jinja`
// (revision 3e22461f, sha256 0a2c8073…), rendered with jinja2 as transformers
// renders it (`trim_blocks`, `lstrip_blocks`, `add_generation_prompt: true`),
// minus the leading `<bos>`, which core never writes for any Gemma: the
// runtime adds it.
import 'package:flutter_edge_ai/src/extensions.dart';
import 'package:flutter_edge_ai/src/message.dart';
import 'package:flutter_edge_ai/src/model.dart';
import 'package:flutter_test/flutter_test.dart';

String _render(List<Message> messages) => messages
    .map(
      (m) => m.transformToChatPrompt(
        type: ModelType.gemma4,
        fileType: ModelFileType.binary,
      ),
    )
    .join();

void main() {
  group('ModelType.gemma4 on .bin/.tflite', () {
    test('one user message: its turn, then the generation prompt', () {
      expect(
        _render(const [Message(text: 'Hello', isUser: true)]),
        '<|turn>user\nHello<turn|>\n<|turn>model\n',
      );
    });

    test('a conversation renders byte for byte as the template does', () {
      expect(
        _render(const [
          Message(text: 'Name a yellow fruit.', isUser: true),
          Message(text: 'Banana.'),
          Message(text: 'Which one?', isUser: true),
        ]),
        '<|turn>user\nName a yellow fruit.<turn|>\n'
        '<|turn>model\nBanana.<turn|>\n'
        '<|turn>user\nWhich one?<turn|>\n'
        '<|turn>model\n',
      );
    });

    test('user text is trimmed, as the template trims it', () {
      expect(
        _render(const [Message(text: '  padded question \n', isUser: true)]),
        '<|turn>user\npadded question<turn|>\n<|turn>model\n',
      );
    });

    test('earlier thinking is dropped from a model reply', () {
      expect(
        _render(const [
          Message(text: 'Q1', isUser: true),
          Message(text: '<|channel>thought\nlet me think<channel|>Answer one.'),
          Message(text: 'Q2', isUser: true),
        ]),
        '<|turn>user\nQ1<turn|>\n'
        '<|turn>model\nAnswer one.<turn|>\n'
        '<|turn>user\nQ2<turn|>\n'
        '<|turn>model\n',
      );
    });

    test('never writes Gemma 3 markers', () {
      final prompt = _render(const [
        Message(text: 'Hi', isUser: true),
        Message(text: 'Hello.'),
      ]);
      expect(prompt, isNot(contains('<start_of_turn>')));
      expect(prompt, isNot(contains('<end_of_turn>')));
    });
  });

  test('gemmaIt keeps Gemma 3 markers', () {
    expect(
      const Message(text: 'Hello', isUser: true).transformToChatPrompt(
        type: ModelType.gemmaIt,
        fileType: ModelFileType.binary,
      ),
      '<start_of_turn>user\nHello<end_of_turn>\n<start_of_turn>model\n',
    );
  });

  group('cleanResponse', () {
    test('gemma4 strips its trailing end-of-turn marker', () {
      expect(
        ModelThinkingFilter.cleanResponse(
          'Banana.<turn|>\n',
          enableThinking: false,
          modelType: ModelType.gemma4,
          fileType: ModelFileType.binary,
        ),
        'Banana.',
      );
    });

    test('gemmaIt still strips <end_of_turn>', () {
      expect(
        ModelThinkingFilter.cleanResponse(
          'Banana.<end_of_turn>',
          enableThinking: false,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.binary,
        ),
        'Banana.',
      );
    });
  });
}
