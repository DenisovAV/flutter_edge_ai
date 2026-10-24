// The conversation of the MediaPipe web session (#705): what is sent on turn 2.
import 'dart:typed_data';

import 'package:flutter_edge_ai_mediapipe/src/web/web_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

String _text(List<PromptPart> prompt) =>
    prompt.whereType<TextPromptPart>().map((p) => p.text).join();

void main() {
  const g4 = WebChatTemplate.gemma4;

  test('turn 2 carries the model reply of turn 1', () {
    final c = WebConversation(template: g4);
    c.addUser([TextPromptPart('Name a fruit that is yellow.')]);
    c.beginGeneration();
    c.completeGeneration('Banana.');
    c.addUser([TextPromptPart('Which one did you just name?')]);
    expect(
      _text(c.beginGeneration()),
      '<|turn>user\nName a fruit that is yellow.<turn|>\n'
      '<|turn>model\nBanana.<turn|>\n'
      '<|turn>user\nWhich one did you just name?<turn|>\n'
      '<|turn>model\n',
    );
  });

  test('gemma 3 markers', () {
    final c = WebConversation(template: WebChatTemplate.gemma3);
    c.addUser([TextPromptPart('hi')]);
    expect(
      _text(c.render()),
      '<start_of_turn>user\nhi<end_of_turn>\n<start_of_turn>model\n',
    );
  });

  test('no template: plain text separated by line breaks', () {
    final c = WebConversation();
    c.addUser([TextPromptPart('a')]);
    c.completeGeneration('b');
    c.addUser([TextPromptPart('c')]);
    expect(_text(c.render()), 'a\nb\nc');
  });

  test('consecutive user messages are one turn', () {
    final c = WebConversation(template: g4);
    c.addUser([TextPromptPart('tools')]);
    c.addUser([TextPromptPart('question')]);
    expect(
      _text(c.render()),
      '<|turn>user\ntools\nquestion<turn|>\n<|turn>model\n',
    );
  });

  test('a replayed model message is a turn, and is not added twice', () {
    final c = WebConversation(template: g4);
    c.addUser([TextPromptPart('q1')]);
    c.addModel('a1');
    c.addUser([TextPromptPart('q2')]);
    expect(
      _text(c.render()),
      '<|turn>user\nq1<turn|>\n<|turn>model\na1<turn|>\n'
      '<|turn>user\nq2<turn|>\n<|turn>model\n',
    );
  });

  test('stop keeps the generated partial', () {
    final c = WebConversation(template: g4);
    c.addUser([TextPromptPart('q')]);
    c.beginGeneration();
    c.stopGeneration('Mango, which is');
    c.addUser([TextPromptPart('go on')]);
    expect(_text(c.render()), contains('<|turn>model\nMango, which is<turn|>'));
    expect(c.isGenerating, isFalse);
  });

  test('stop with nothing generated leaves the user turn unanswered', () {
    final c = WebConversation(template: g4);
    c.addUser([TextPromptPart('q')]);
    c.beginGeneration();
    c.stopGeneration('');
    expect(c.hasPendingUserTurn, isTrue);
  });

  test('an error drops only the pending turn', () {
    final c = WebConversation(template: g4);
    c.addUser([TextPromptPart('q1')]);
    c.completeGeneration('a1');
    c.addUser([TextPromptPart('q2')]);
    c.beginGeneration();
    c.failGeneration();
    expect(
      _text(c.render()),
      '<|turn>user\nq1<turn|>\n<|turn>model\na1<turn|>\n<|turn>model\n',
    );
  });

  test('a second generation while one runs is refused', () {
    final c = WebConversation(template: g4);
    c.addUser([TextPromptPart('q')]);
    c.beginGeneration();
    expect(c.beginGeneration, throwsStateError);
  });

  group('images', () {
    final img = ImagePromptPart('data:image/png;base64,AA==');

    test('stay in the history in reading order', () {
      final c = WebConversation(template: g4, maxImages: 2);
      c.addUser([img, TextPromptPart('what is this')]);
      c.completeGeneration('a cat');
      c.addUser([TextPromptPart('and now?')]);
      final p = c.render();
      expect(p.whereType<ImagePromptPart>(), hasLength(1));
      expect(p.first, isA<TextPromptPart>());
      expect(p[1], same(img));
      expect(_text(p), contains('a cat'));
    });

    test('past maxNumImages fail naming it, and nothing is dropped', () {
      final c = WebConversation(template: g4, maxImages: 1);
      c.addUser([img, TextPromptPart('one')]);
      c.completeGeneration('ok');
      expect(
        () => c.addUser([
          ImagePromptPart('data:image/png;base64,BB=='),
          TextPromptPart('two'),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('maxNumImages: 1'),
          ),
        ),
      );
      expect(c.imageCount, 1);
      expect(_text(c.render()), contains('one'));
    });

    test('audio parts are kept', () {
      final c = WebConversation(template: g4);
      c.addUser([AudioPromptPart(Uint8List(4)), TextPromptPart('transcribe')]);
      expect(c.render().whereType<AudioPromptPart>(), hasLength(1));
    });
  });

  test('clear forgets everything', () {
    final c = WebConversation(template: g4);
    c.addUser([TextPromptPart('q')]);
    c.clear();
    expect(
      c.render().map((p) => (p as TextPromptPart).text).join(),
      '<|turn>model\n',
    );
  });
}
