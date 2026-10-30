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

  /// The next generate() answers only when the test completes this.
  Completer<String>? held;

  /// A cancelled call ends only when the test lets it.
  bool endOnCancel = true;
  StreamController<String>? live;

  @override
  Future<int> sizeInTokens(String text) async => text.length;

  @override
  Future<String> generate(List<PromptPart> prompt) async {
    prompts.add(prompt);
    if (failWith != null) throw failWith!;
    if (held case final hold?) {
      held = null;
      return hold.future;
    }
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
  Duration previousCallWait = const Duration(seconds: 30),
}) => WebModelSession(
  backend: b,
  onClose: () {},
  modelType: ModelType.gemma4,
  supportImage: image,
  systemInstruction: system,
  template: WebChatTemplate.gemma4,
  maxImages: maxImages,
  previousCallWait: previousCallWait,
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

  test('an error keeps the turn it failed on, with the system instruction '
      'and the tools prompt', () async {
    final b = FakeBackend(['ok'])..failWith = StateError('webgpu lost');
    final s = _session(b, system: 'Be brief');
    // The chat sends the tools prompt and then the question.
    await s.addQueryChunk(const Message(text: 'TOOLS', isUser: true));
    await s.addQueryChunk(const Message(text: 'Q1', isUser: true));
    await expectLater(s.getResponse(), throwsStateError);
    b.failWith = null;
    await s.getResponse();
    final sent = _text(b.prompts.last);
    expect(sent, contains('[System: Be brief]'));
    expect(sent, contains('TOOLS'));
    expect(sent, contains('Q1'));
    expect(b.prompts.first, isNotEmpty);
  });

  test('a stream error keeps the turn it failed on', () async {
    final b = FakeBackend(['ok'])..failWith = StateError('lost');
    final s = _session(b, system: 'Be brief');
    await s.addQueryChunk(const Message(text: 'Q1', isUser: true));
    await expectLater(s.getResponseAsync().toList(), throwsStateError);
    b.failWith = null;
    await s.getResponse();
    expect(
      _text(b.prompts.last),
      '<|turn>user\n[System: Be brief]\n\nQ1<turn|>\n<|turn>model\n',
    );
  });

  test('a message refused by the conversation does not use up the system '
      'instruction', () async {
    final b = FakeBackend(['x']);
    final s = _session(b, system: 'Be brief', image: true, maxImages: 1);
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);
    // The first message is the refused one: two images, room for one.
    await expectLater(
      s.addQueryChunk(
        Message.withImages(text: 'a', imageBytes: [png, png], isUser: true),
      ),
      throwsStateError,
    );
    await s.addQueryChunk(const Message(text: 'plain', isUser: true));
    await s.getResponse();
    expect(
      _text(b.prompts.single),
      '<|turn>user\n[System: Be brief]\n\nplain<turn|>\n<|turn>model\n',
    );
  });

  test('addQueryChunk while a generation runs is refused and changes '
      'nothing', () async {
    final b = FakeBackend([]);
    final s = _session(b);
    await s.addQueryChunk(_user);
    s.getResponseAsync().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    b.live!.add('ra');
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      s.addQueryChunk(const Message(text: 'B', isUser: true)),
      throwsStateError,
    );
    await expectLater(
      s.addQueryChunk(const Message(text: 'late reply')),
      throwsStateError,
    );
    await b.live!.close();
    await Future<void>.delayed(Duration.zero);
    b.replies.add('x');
    await s.addQueryChunk(const Message(text: 'C', isUser: true));
    await s.getResponse();
    expect(
      _text(b.prompts.last),
      '<|turn>user\nName a yellow fruit.<turn|>\n<|turn>model\nra<turn|>\n'
      '<|turn>user\nC<turn|>\n<|turn>model\n',
    );
  });

  group('a closed session', () {
    test('does not cancel the generation of the live one', () async {
      final b = FakeBackend([]);
      final old = _session(b);
      await old.close();
      final live = _session(b);
      await live.addQueryChunk(_user);
      live.getResponseAsync().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await old.stopGeneration();
      expect(b.cancels, 0);
      await live.stopGeneration();
      expect(b.cancels, 1);
    });

    test('an idle session does not cancel either', () async {
      final b = FakeBackend([]);
      final s = _session(b);
      await s.stopGeneration();
      expect(b.cancels, 0);
    });

    test('that closes while its call waits for the previous one does not '
        'start', () async {
      final b = FakeBackend([])..endOnCancel = false;
      final s = _session(b);
      await s.addQueryChunk(_user);
      s.getResponseAsync().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await s.stopGeneration(); // the stopped call is still ending
      await s.addQueryChunk(const Message(text: 'go on', isUser: true));
      final waiting = s.getResponse();
      final outcome = expectLater(waiting, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(b.cancels, 1);
      await s.close();
      expect(
        b.cancels,
        1,
        reason: 'the waiting call never reached the backend: nothing to cancel',
      );
      await b.live!.close();
      await outcome;
      expect(b.prompts, hasLength(1));
      expect(s.pendingCalls, 0);
    });

    test('throws StateError from addQueryChunk, getResponse and '
        'getResponseAsync', () async {
      final b = FakeBackend(['x']);
      final s = _session(b);
      await s.close();
      await expectLater(s.addQueryChunk(_user), throwsStateError);
      await expectLater(s.getResponse(), throwsStateError);
      expect(s.getResponseAsync, throwsStateError);
      expect(b.prompts, isEmpty);
    });
  });

  group('Gemma 4 on the .task template', () {
    test('trims what the user said and strips thinking from a reply, as a '
        '.bin does', () async {
      final b = FakeBackend([
        '<|channel>thought\nhmm<channel|>  Banana.  \n',
        'x',
      ]);
      final s = _session(b);
      await s.addQueryChunk(const Message(text: '  Hi  \n', isUser: true));
      await s.getResponse();
      await s.addQueryChunk(const Message(text: 'Ok?', isUser: true));
      await s.getResponse();
      String bin(String text, {bool isUser = true}) =>
          Message(text: text, isUser: isUser).transformToChatPrompt(
            type: ModelType.gemma4,
            fileType: ModelFileType.binary,
          );
      expect(
        _text(b.prompts[1]),
        bin('  Hi  \n') +
            bin(
              '<|channel>thought\nhmm<channel|>  Banana.  \n',
              isUser: false,
            ) +
            bin('Ok?'),
      );
    });
  });

  group('Gemma 4 thinking is stripped', () {
    test('from a reply the chat replays', () async {
      final b = FakeBackend(['x']);
      final s = _session(b);
      await s.addQueryChunk(_user);
      await s.addQueryChunk(
        const Message(text: '<|channel>thought\nhm<channel|>  Banana.  \n'),
      );
      await s.addQueryChunk(const Message(text: 'Ok?', isUser: true));
      await s.getResponse();
      expect(
        _text(b.prompts.single),
        contains('<|turn>model\nBanana.<turn|>\n<|turn>user\nOk?'),
      );
    });

    test('from a stopped partial', () async {
      final b = FakeBackend([]);
      final s = _session(b);
      await s.addQueryChunk(_user);
      s.getResponseAsync().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      b.live!.add('<|channel>thought\nhm<channel|>  Ban');
      await Future<void>.delayed(Duration.zero);
      await s.stopGeneration();
      await s.addQueryChunk(const Message(text: 'Ok?', isUser: true));
      b.replies.add('x');
      await s.getResponse();
      expect(
        _text(b.prompts.last),
        contains('<|turn>model\nBan<turn|>\n<|turn>user\nOk?'),
      );
    });
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

  test('a stop while getResponse waits for the previous call ends it before '
      'it starts', () async {
    final b = FakeBackend([])..endOnCancel = false;
    final s = _session(b);
    await s.addQueryChunk(_user);
    s.getResponseAsync().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    final first = b.live!;
    first.add('Mango');
    await Future<void>.delayed(Duration.zero);
    await s.stopGeneration();

    await s.addQueryChunk(const Message(text: 'go on', isUser: true));
    b.replies.add('never sent');
    final next = s.getResponse();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(b.cancels, 1);
    await s.stopGeneration();
    expect(
      b.cancels,
      1,
      reason: 'the waiting call never reached the backend: nothing to cancel',
    );
    await first.close();
    expect(await next, isEmpty);
    expect(b.prompts, hasLength(1), reason: 'the stopped call must not run');

    // The stopped turn is still the user's, and the next call answers it.
    b.replies
      ..clear()
      ..add('ok');
    await s.getResponse();
    expect(
      _text(b.prompts.last),
      endsWith(
        '<|turn>model\nMango<turn|>\n<|turn>user\ngo on<turn|>\n<|turn>model\n',
      ),
    );
  });

  group('overlapping blocking calls', () {
    test('a stop ends both, and the running one\'s late reply is not '
        'recorded', () async {
      final b = FakeBackend([]);
      final s = _session(b);
      await s.addQueryChunk(const Message(text: 'a', isUser: true));
      final hold = b.held = Completer<String>();
      final first = s.getResponse();
      final second = s.getResponse();
      await Future<void>.delayed(Duration.zero);
      await s.stopGeneration();
      expect(b.cancels, 1);
      hold.complete('partial');
      expect(await first, 'partial');
      expect(await second, isEmpty);
      expect(b.prompts, hasLength(1), reason: 'the waiting call never ran');

      await s.addQueryChunk(const Message(text: 'b', isUser: true));
      b.replies.add('ok');
      await s.getResponse();
      expect(_text(b.prompts.last), isNot(contains('partial')));
      expect(_text(b.prompts.last), '<|turn>user\na\nb<turn|>\n<|turn>model\n');
    });

    test('a call still running behind two that gave up waiting stays '
        'stoppable', () async {
      final b = FakeBackend([]);
      final s = _session(b, previousCallWait: const Duration(milliseconds: 5));
      await s.addQueryChunk(const Message(text: 'a', isUser: true));
      final hold = b.held = Completer<String>();
      final first = s.getResponse();
      // Both wait at once, past their limit, and are refused: the first is
      // still running.
      final second = s.getResponse();
      final third = s.getResponse();
      await expectLater(second, throwsStateError);
      await expectLater(third, throwsStateError);

      await s.stopGeneration();
      expect(b.cancels, 1, reason: 'the running call was found and cancelled');
      hold.complete('late');
      await first;
      expect(s.pendingCalls, 0);

      await s.addQueryChunk(const Message(text: 'b', isUser: true));
      b.replies.add('ok');
      await s.getResponse();
      expect(_text(b.prompts.last), isNot(contains('late')));
    });

    test('a close ends both, and the late reply lands nowhere', () async {
      final b = FakeBackend([]);
      final s = _session(b);
      await s.addQueryChunk(const Message(text: 'a', isUser: true));
      final hold = b.held = Completer<String>();
      final first = s.getResponse();
      final second = expectLater(s.getResponse(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      await s.close();
      expect(b.cancels, 1);
      // The waiting call is refused at the close, not when the first ends.
      await second;
      hold.complete('late');
      expect(await first, 'late');
      expect(b.prompts, hasLength(1));
    });
  });

  group('a call that waits for an earlier one', () {
    test('a stopped call that never ends delays only the next turn', () async {
      const wait = Duration(milliseconds: 200);
      final b = FakeBackend([])..endOnCancel = false;
      final s = _session(b, previousCallWait: wait);
      await s.addQueryChunk(_user);
      s.getResponseAsync().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await s.stopGeneration(); // its stream never closes

      final took = <Duration>[];
      for (final text in ['one', 'two', 'three']) {
        await s.addQueryChunk(Message(text: text, isUser: true));
        b.replies.add('ok');
        final clock = Stopwatch()..start();
        await s.getResponse();
        took.add(clock.elapsed);
      }
      // Timers and Stopwatch round differently; a few ms of slack.
      expect(took[0], greaterThan(wait - const Duration(milliseconds: 20)));
      expect(took[1], lessThan(wait ~/ 2));
      expect(took[2], lessThan(wait ~/ 2));
      expect(s.pendingCalls, 0);
    });

    test('a stream behind a call that is still running is refused after the '
        'wait, and the running call stays stoppable', () async {
      final b = FakeBackend([]);
      final s = _session(b, previousCallWait: const Duration(milliseconds: 5));
      await s.addQueryChunk(const Message(text: 'a', isUser: true));
      final hold = b.held = Completer<String>();
      final first = s.getResponse();
      final errors = <Object>[];
      final done = Completer<void>();
      s.getResponseAsync().listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      await done.future;
      expect(errors.single, isA<StateError>());

      await s.stopGeneration();
      expect(b.cancels, 1);
      hold.complete('late');
      await first;
      expect(s.pendingCalls, 0);
    });

    test(
      'a stream stopped while it waits never starts, and ends at once',
      () async {
        final b = FakeBackend([]);
        final s = _session(b);
        await s.addQueryChunk(const Message(text: 'a', isUser: true));
        final hold = b.held = Completer<String>();
        final first = s.getResponse();
        final done = Completer<void>();
        s.getResponseAsync().listen((_) {}, onDone: done.complete);
        await Future<void>.delayed(Duration.zero);

        await s.stopGeneration();
        await done.future.timeout(const Duration(seconds: 1));
        expect(
          b.cancels,
          1,
          reason: 'only the call in the backend is cancelled',
        );
        hold.complete('late');
        await first;
        await Future<void>.delayed(Duration.zero);
        expect(b.prompts, hasLength(1), reason: 'the stream never started');
        expect(s.pendingCalls, 0);
      },
    );

    test(
      'a stream closed while it waits never starts, and ends at once',
      () async {
        final b = FakeBackend([]);
        final s = _session(b);
        await s.addQueryChunk(const Message(text: 'a', isUser: true));
        final hold = b.held = Completer<String>();
        final first = s.getResponse();
        final done = Completer<void>();
        s.getResponseAsync().listen((_) {}, onDone: done.complete);
        await Future<void>.delayed(Duration.zero);

        await s.close();
        await done.future.timeout(const Duration(seconds: 1));
        expect(b.cancels, 1);
        hold.complete('late');
        await first;
        await Future<void>.delayed(Duration.zero);
        expect(b.prompts, hasLength(1), reason: 'the stream never started');
        expect(s.pendingCalls, 0);
      },
    );

    test('a call queued later starts when the delayed turn ends, not at its '
        'own timeout', () async {
      const wait = Duration(milliseconds: 200);
      final b = FakeBackend([])..endOnCancel = false;
      final s = _session(b, previousCallWait: wait);
      await s.addQueryChunk(_user);
      s.getResponseAsync().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await s.stopGeneration(); // its stream never closes

      await s.addQueryChunk(const Message(text: 'go on', isUser: true));
      final delayedDone = Completer<void>();
      s.getResponseAsync().listen((_) {}, onDone: delayedDone.complete);
      await Future<void>.delayed(wait ~/ 2);
      // Queued half a wait later; its own limit runs out at 1.5 waits.
      final later = s.getResponse();
      await Future<void>.delayed(wait ~/ 2 + const Duration(milliseconds: 30));
      expect(b.prompts, hasLength(2), reason: 'the delayed turn is running');
      b.replies.add('x');
      b.live!
        ..add('Ok.')
        ..close();
      await delayedDone.future;
      final clock = Stopwatch()..start();
      await later;
      expect(clock.elapsed, lessThan(wait ~/ 4));
      expect(b.prompts, hasLength(3));
    });

    test('a call queued behind the turn a never-ending stopped call delayed '
        'is not refused', () async {
      const wait = Duration(milliseconds: 200);
      final b = FakeBackend([])..endOnCancel = false;
      final s = _session(b, previousCallWait: wait);
      await s.addQueryChunk(_user);
      s.getResponseAsync().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      final stuck = b.live!;
      await s.stopGeneration(); // its stream never closes

      await s.addQueryChunk(const Message(text: 'go on', isUser: true));
      s.getResponseAsync().listen((_) {});
      final queued = s.getResponse();
      var refused = false;
      unawaited(queued.then((_) {}, onError: (Object _) => refused = true));
      // Past the first wait the stopped call is let go of and the stream
      // runs; the blocking call then waits for the stream afresh, as for any
      // call that runs, instead of being refused alongside it.
      await Future<void>.delayed(wait * 1.5);
      expect(b.prompts, hasLength(2), reason: 'the second stream started');
      expect(identical(b.live, stuck), isFalse);
      expect(refused, isFalse);

      await s.stopGeneration();
      expect(await queued, isEmpty);
    });

    test('a blocking call behind a waiting stream queues instead of failing, '
        'and a stop ends both', () async {
      final b = FakeBackend([])..endOnCancel = false;
      final s = _session(b);
      await s.addQueryChunk(_user);
      s.getResponseAsync().listen((_) {});
      await Future<void>.delayed(Duration.zero);
      final first = b.live!;
      first.add('Mango');
      await Future<void>.delayed(Duration.zero);
      await s.stopGeneration();

      // The stream waits for the stopped call; the blocking call waits for it.
      await s.addQueryChunk(const Message(text: 'go on', isUser: true));
      final streamed = <String>[];
      final done = Completer<void>();
      s.getResponseAsync().listen(streamed.add, onDone: done.complete);
      final blocking = s.getResponse();
      await first.close();
      await Future<void>.delayed(Duration.zero);
      expect(b.prompts, hasLength(2), reason: 'the stream runs first');
      b.live!.add('Ok');
      await Future<void>.delayed(Duration.zero);

      await s.stopGeneration();
      await done.future;
      expect(streamed.join(), 'Ok');
      // Queued, not refused: the stop ends it before it starts.
      expect(await blocking, isEmpty);
      expect(b.prompts, hasLength(2));
      expect(s.pendingCalls, 1, reason: 'the stopped stream is still ending');
      await b.live!.close();
      await Future<void>.delayed(Duration.zero);
      expect(s.pendingCalls, 0);
    });
  });

  test('a blocking call queues behind a stream, runs after it, and sees '
      'its reply', () async {
    final b = FakeBackend([]);
    final s = _session(b);
    await s.addQueryChunk(_user);
    final streamed = <String>[];
    final done = Completer<void>();
    s.getResponseAsync().listen(streamed.add, onDone: done.complete);
    await Future<void>.delayed(Duration.zero);
    final live = b.live!;
    // Queued while the stream runs; addQueryChunk is refused until it ends,
    // so this call has no user message of its own.
    final blocking = s.getResponse();
    await Future<void>.delayed(Duration.zero);
    expect(b.prompts, hasLength(1), reason: 'it waits for the stream');

    b.replies.add('Next.');
    live
      ..add('Ok.')
      ..close();
    await done.future;
    expect(streamed.join(), 'Ok.');
    expect(await blocking, 'Next.');
    expect(b.prompts, hasLength(2));
    expect(_text(b.prompts.last), contains('<|turn>model\nOk.<turn|>'));
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
      // The pieces that came after the newer call began are in the history.
      b.replies.add('y');
      await s.addQueryChunk(const Message(text: 'next', isUser: true));
      await s.getResponse();
      expect(_text(b.prompts.last), contains('abcdef'));
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
