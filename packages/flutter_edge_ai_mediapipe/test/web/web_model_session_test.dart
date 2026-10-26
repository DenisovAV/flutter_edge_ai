// WebModelSession over a fake backend, and a real InferenceChat on top of it.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/web_model_session.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/web_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

String _text(List<PromptPart> prompt) =>
    prompt.whereType<TextPromptPart>().map((p) => p.text).join();

/// Answers from a script and records every prompt it was sent.
class FakeBackend implements WebLlmBackend {
  FakeBackend(this.replies);
  final List<String> replies;
  final List<List<PromptPart>> prompts = [];
  Object? failWith;
  int cancels = 0;

  /// A cancelled call ends only when the test lets it.
  bool endOnCancel = true;
  StreamController<String>? live;

  @override
  Future<int> sizeInTokens(String text) async => text.length;

  @override
  Future<String> generate(List<PromptPart> prompt) async {
    prompts.add(prompt);
    if (failWith != null) throw failWith!;
    return replies.removeAt(0);
  }

  @override
  Stream<String> generateStream(List<PromptPart> prompt) {
    prompts.add(prompt);
    if (failWith != null) return Stream.error(failWith!);
    if (replies.isEmpty) return (live = StreamController<String>()).stream;
    final reply = replies.removeAt(0);
    return Stream.fromIterable([
      for (var i = 0; i < reply.length; i += 3)
        reply.substring(i, i + 3 > reply.length ? reply.length : i + 3),
    ]);
  }

  @override
  void cancel() {
    cancels++;
    // A cancelled call ends; the next one waits for that.
    if (endOnCancel) live?.close();
  }
}

WebModelSession _session(
  FakeBackend b, {
  int? maxImages,
  bool image = false,
  String? system,
}) => WebModelSession(
  backend: b,
  onClose: () {},
  modelType: ModelType.gemma4,
  supportImage: image,
  systemInstruction: system,
  template: WebChatTemplate.gemma4,
  maxImages: maxImages,
);

const _user = Message(text: 'Name a yellow fruit.', isUser: true);

void main() {
  test('getResponse: turn 2 is sent the reply of turn 1', () async {
    final b = FakeBackend(['Banana.', 'Banana.']);
    final s = _session(b);
    await s.addQueryChunk(_user);
    expect(await s.getResponse(), 'Banana.');
    await s.addQueryChunk(const Message(text: 'Which one?', isUser: true));
    await s.getResponse();
    expect(_text(b.prompts[1]), contains('<|turn>model\nBanana.<turn|>'));
    expect(_text(b.prompts[1]), contains('Which one?'));
  });

  test('getResponseAsync records the raw text it streamed', () async {
    final b = FakeBackend(['Mango pulp', 'x']);
    final s = _session(b);
    await s.addQueryChunk(_user);
    expect((await s.getResponseAsync().toList()).join(), 'Mango pulp');
    await s.addQueryChunk(const Message(text: 'again', isUser: true));
    await s.getResponse();
    expect(_text(b.prompts[1]), contains('<|turn>model\nMango pulp<turn|>'));
  });

  test('a model message replayed by the chat becomes a model turn', () async {
    final b = FakeBackend(['next']);
    final s = _session(b);
    await s.addQueryChunk(_user);
    await s.addQueryChunk(const Message(text: 'Banana.'));
    await s.addQueryChunk(const Message(text: 'and?', isUser: true));
    await s.getResponse();
    expect(
      _text(b.prompts.single),
      '<|turn>user\nName a yellow fruit.<turn|>\n<|turn>model\nBanana.<turn|>\n'
      '<|turn>user\nand?<turn|>\n<|turn>model\n',
    );
  });

  test('an error drops only the pending turn', () async {
    final b = FakeBackend(['ok', 'fine'])..failWith = null;
    final s = _session(b);
    await s.addQueryChunk(_user);
    await s.getResponse();
    await s.addQueryChunk(const Message(text: 'boom', isUser: true));
    b.failWith = StateError('webgpu lost');
    await expectLater(s.getResponse(), throwsStateError);
    b.failWith = null;
    await s.addQueryChunk(const Message(text: 'retry', isUser: true));
    await s.getResponse();
    final sent = _text(b.prompts.last);
    expect(sent, contains('ok'));
    expect(sent, isNot(contains('boom')));
    expect(sent, contains('retry'));
  });

  test('a stream error drops only the pending turn', () async {
    final b = FakeBackend(['ok'])..failWith = null;
    final s = _session(b);
    await s.addQueryChunk(_user);
    await s.getResponse();
    await s.addQueryChunk(const Message(text: 'boom', isUser: true));
    b.failWith = StateError('lost');
    await expectLater(s.getResponseAsync().toList(), throwsStateError);
    b.failWith = null;
    b.replies.add('again');
    await s.addQueryChunk(const Message(text: 'retry', isUser: true));
    await s.getResponse();
    expect(_text(b.prompts.last), isNot(contains('boom')));
  });

  test('stop keeps the generated partial and cancels the backend', () async {
    final b = FakeBackend([]);
    final s = _session(b);
    await s.addQueryChunk(_user);
    final seen = <String>[];
    s.getResponseAsync().listen(seen.add);
    await Future<void>.delayed(Duration.zero);
    b.live!.add('Mango, which');
    await Future<void>.delayed(Duration.zero);
    await s.stopGeneration();
    expect(b.cancels, 1);
    b.replies.add('x');
    await s.addQueryChunk(const Message(text: 'go on', isUser: true));
    await s.getResponse();
    expect(
      _text(b.prompts.last),
      contains('<|turn>model\nMango, which<turn|>'),
    );
  });

  test('the next call waits until the stopped one has ended', () async {
    final b = FakeBackend([])..endOnCancel = false;
    final s = _session(b);
    await s.addQueryChunk(_user);
    s.getResponseAsync().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    b.live!.add('Mango');
    await Future<void>.delayed(Duration.zero);
    await s.stopGeneration();

    await s.addQueryChunk(const Message(text: 'go on', isUser: true));
    b.replies.add('x');
    final next = s.getResponse();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(b.prompts, hasLength(1), reason: 'the stopped call is still ending');
    await b.live!.close();
    await next;
    expect(b.prompts, hasLength(2));
  });

  test('closing the session does not need the backend closed', () async {
    final b = FakeBackend(['a']);
    final s = _session(b);
    await s.addQueryChunk(_user);
    await s.close();
    expect(b.cancels, 0);
  });

  test('image above maxNumImages fails with an error naming it', () async {
    final b = FakeBackend([]);
    final s = _session(b, image: true, maxImages: 1);
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);
    await s.addQueryChunk(Message(text: 'a', isUser: true, imageBytes: png));
    await expectLater(
      s.addQueryChunk(Message(text: 'b', isUser: true, imageBytes: png)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('maxNumImages'),
        ),
      ),
    );
    expect(s.imageCount, 1);
  });

  test('the system instruction prefix is kept', () async {
    final b = FakeBackend(['x']);
    final s = _session(b, system: 'Be brief');
    await s.addQueryChunk(_user);
    await s.getResponse();
    expect(_text(b.prompts.single), contains('[System: Be brief]'));
  });

  group('InferenceChat over fresh sessions', () {
    test(
      'turn 2 sees turn 1, also after the chat rebuilds its session',
      () async {
        final b = FakeBackend(['Banana.', 'Banana, as I said.', 'ok']);
        final chat = InferenceChat(
          sessionCreator: () async => _session(b),
          maxTokens: 1024,
          modelType: ModelType.gemma4,
        );
        await chat.initSession();
        await chat.addQuery(_user);
        await chat.generateChatResponse();
        await chat.addQuery(const Message(text: 'Which one?', isUser: true));
        await chat.generateChatResponse();
        expect(_text(b.prompts[1]), contains('<|turn>model\nBanana.<turn|>'));

        // The chat closes its session and replays its history into a new one.
        await chat.clearHistory(
          replayHistory: [
            ..._user.text.isEmpty ? const [] : [_user],
            const Message(text: 'Banana.'),
          ],
        );
        await chat.addQuery(const Message(text: 'last?', isUser: true));
        await chat.generateChatResponse();
        expect(
          _text(b.prompts.last),
          '<|turn>user\nName a yellow fruit.<turn|>\n<|turn>model\nBanana.<turn|>\n'
          '<|turn>user\nlast?<turn|>\n<|turn>model\n',
        );
      },
    );
  });

  group('messages the platform formats by hand', () {
    String formatted(
      String text, {
      required ModelType type,
      required ModelFileType fileType,
      bool isUser = true,
    }) => Message(
      text: text,
      isUser: isUser,
    ).transformToChatPrompt(type: type, fileType: fileType);

    WebModelSession bySession(
      FakeBackend b,
      ModelType type,
      ModelFileType fileType,
    ) => WebModelSession(
      backend: b,
      onClose: () {},
      modelType: type,
      fileType: fileType,
      // The Gemma 3 markers a `.bin` falls back to; they must stay unused.
      template: WebChatTemplate.gemma3,
    );

    test('a gemmaIt .bin is sent wrapped once', () async {
      final b = FakeBackend(['Hello.']);
      final s = bySession(b, ModelType.gemmaIt, ModelFileType.binary);
      await s.addQueryChunk(const Message(text: 'Hi', isUser: true));
      await s.getResponse();
      expect(
        _text(b.prompts.single),
        '<start_of_turn>user\nHi<end_of_turn>\n<start_of_turn>model\n',
      );
    });

    for (final type in [
      ModelType.gemmaIt,
      ModelType.qwen,
      ModelType.deepSeek,
      ModelType.llama,
    ]) {
      test('a $type .bin keeps its reply closed in the history', () async {
        final b = FakeBackend(['Hello.', 'Fine.']);
        final s = bySession(b, type, ModelFileType.binary);
        await s.addQueryChunk(const Message(text: 'Hi', isUser: true));
        await s.getResponse();
        await s.addQueryChunk(const Message(text: 'Ok?', isUser: true));
        await s.getResponse();
        expect(
          _text(b.prompts[1]),
          formatted('Hi', type: type, fileType: ModelFileType.binary) +
              formatted(
                'Hello.',
                type: type,
                fileType: ModelFileType.binary,
                isUser: false,
              ) +
              formatted('Ok?', type: type, fileType: ModelFileType.binary),
        );
      });
    }

    test('FunctionGemma on a .task is sent wrapped once', () async {
      final b = FakeBackend(['Hello.']);
      final s = bySession(b, ModelType.functionGemma, ModelFileType.task);
      await s.addQueryChunk(const Message(text: 'Hi', isUser: true));
      await s.getResponse();
      expect(
        _text(b.prompts.single),
        formatted(
          'Hi',
          type: ModelType.functionGemma,
          fileType: ModelFileType.task,
        ),
      );
    });
  });

  test('a second getResponseAsync while one streams does not throw', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final b = FakeBackend([]);
      final s = _session(b);
      await s.addQueryChunk(_user);
      final first = <String>[];
      s.getResponseAsync().listen(first.add);
      await Future<void>.delayed(Duration.zero);
      final firstLive = b.live!;
      firstLive.add('abc');
      await Future<void>.delayed(Duration.zero);
      s.getResponseAsync().listen((_) {});
      // The pieces that come after the newer call began.
      firstLive.add('def');
      await Future<void>.delayed(Duration.zero);
      await firstLive.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The first reply is complete in the history.
      b.live?.add('x');
      await b.live?.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(first, ['abc']);
    }, (e, _) => errors.add(e));
    expect(errors, isEmpty);
  });

  test('a replayed thinking message does not enter the history', () async {
    final b = FakeBackend(['ok']);
    final s = _session(b);
    await s.addQueryChunk(_user);
    await s.addQueryChunk(
      const Message(text: 'hidden thought', type: MessageType.thinking),
    );
    await s.getResponse();
    expect(_text(b.prompts.single), isNot(contains('hidden thought')));
  });
}
