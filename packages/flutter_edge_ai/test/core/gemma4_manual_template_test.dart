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

    test('a reply is trimmed after its thinking is dropped', () {
      expect(
        _render(const [
          Message(text: 'Q1', isUser: true),
          Message(text: '<|channel>thought\nx<channel|>\n\nAnswer one.\n'),
          Message(text: 'Q2', isUser: true),
        ]),
        '<|turn>user\nQ1<turn|>\n'
        '<|turn>model\nAnswer one.<turn|>\n'
        '<|turn>user\nQ2<turn|>\n'
        '<|turn>model\n',
      );
    });

    // Edge cases of the template's strip_thinking macro, each rendered with
    // jinja2 from the same template revision.
    group('strip_thinking', () {
      String reply(String text) => _render([
        const Message(text: 'Q1', isUser: true),
        Message(text: text),
        const Message(text: 'Q2', isUser: true),
      ]);

      String expected(String kept) =>
          '<|turn>user\nQ1<turn|>\n'
          '<|turn>model\n$kept<turn|>\n'
          '<|turn>user\nQ2<turn|>\n'
          '<|turn>model\n';

      test('drops every thinking block, not only the first', () {
        expect(
          reply('A<|channel>t1<channel|>B<|channel>t2<channel|>C'),
          expected('ABC'),
        );
      });

      test('an unclosed block (a stopped generation) drops the rest', () {
        expect(reply('Ans<|channel>thought\nstopped mid'), expected('Ans'));
      });

      test('a reply that is only thinking renders empty', () {
        expect(reply('<|channel>thought\nall<channel|>'), expected(''));
      });

      test('a stray closing marker is removed, the text around it kept', () {
        expect(reply('x<channel|>y'), expected('xy'));
      });
    });

    // The template writes a tool result as `<|tool_response>response:…`;
    // this path still writes the legacy block inside a user turn. Pinned as
    // it is today, so that changing it is a decision, not an accident.
    test('a tool response is the legacy block in a user turn', () {
      expect(
        _render([
          Message.toolResponse(
            toolName: 'get_weather',
            response: const {'temp': 20},
          ),
        ]),
        '<|turn>user\n'
        '<tool_response>\n'
        'Tool Name: get_weather\n'
        'Tool Response:\n'
        '{"temp":20}\n'
        '</tool_response><turn|>\n'
        '<|turn>model\n',
      );
    });

    test('every file type with its own template gets the text raw', () {
      for (final fileType in [
        ModelFileType.task,
        ModelFileType.litertlm,
        ModelFileType.builtIn,
        ModelFileType.onnx,
        ModelFileType.gguf,
      ]) {
        expect(
          const Message(
            text: 'Hello',
            isUser: true,
          ).transformToChatPrompt(type: ModelType.gemma4, fileType: fileType),
          'Hello',
          reason: '$fileType',
        );
      }
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

    test('gemma4 strips the marker without a trailing newline', () {
      expect(
        ModelThinkingFilter.cleanResponse(
          'Banana.<turn|>',
          enableThinking: false,
          modelType: ModelType.gemma4,
          fileType: ModelFileType.binary,
        ),
        'Banana.',
      );
    });

    test('gemma4 keeps a <turn|> in the middle of a reply', () {
      expect(
        ModelThinkingFilter.cleanResponse(
          'A<turn|>B',
          enableThinking: false,
          modelType: ModelType.gemma4,
          fileType: ModelFileType.binary,
        ),
        'A<turn|>B',
      );
    });

    test('gemma4 drops thinking and the trailing marker together', () {
      expect(
        ModelThinkingFilter.cleanResponse(
          '<|channel>thought\nx<channel|>Banana.<turn|>\n',
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
