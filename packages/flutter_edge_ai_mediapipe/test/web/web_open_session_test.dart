// Remaining deprecated calls verify that open sessions do not alter the legacy lane.
// ignore_for_file: deprecated_member_use

// openSession and openChat on the web model, over fake MediaPipe globals:
// sessions of their own over one LlmInference, the cap, and what a stop or a
// close of one session does to the others.
//
// Browser-only; tool/test_all.sh, and so CI, runs it with --platform chrome:
//   flutter test --platform chrome test/web/web_open_session_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_media_pipe.dart';

const _hi = Message(text: 'Hi', isUser: true);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

String _prompt(JSAny prompt) => (prompt as JSString).toDart;

/// Runs [body] and returns what it printed.
Future<List<String>> _printed(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines;
}

List<String> _warnings(List<String> lines) => [
  for (final line in lines)
    if (line.contains('every session of this web model shares')) line,
];

void main() {
  test(
    'open sessions keep a conversation each over one LlmInference',
    () async {
      final fake = fakeMediaPipe();
      final model = testModel(supportImage: false, resolver: BlobResolver());

      final a = await model.openSession();
      final b = await model.openSession();
      expect(model.sessions, [a, b]);

      await a.addQueryChunk(const Message(text: 'QA', isUser: true));
      await a.getResponse();
      await b.addQueryChunk(const Message(text: 'QB', isUser: true));
      await b.getResponse();
      await a.addQueryChunk(const Message(text: 'QA2', isUser: true));
      await a.getResponse();

      expect(fake.created, hasLength(1), reason: 'one model for every session');
      final third = _prompt(fake.prompts[2]);
      expect(third, contains('QA'));
      expect(third, contains('QA2'));
      expect(third, isNot(contains('QB')));
      expect(_prompt(fake.prompts[1]), isNot(contains('QA')));
      await model.close();
    },
  );

  test('openSession does not close the legacy session, nor the legacy one '
      'an open session', () async {
    fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final legacy = await model.createSession();
    final open = await model.openSession();
    await legacy.addQueryChunk(_hi);
    await open.addQueryChunk(_hi);
    await model.createSession();
    await open.addQueryChunk(_hi);
    await model.close();
  });

  test('maxConcurrentSessions caps the open sessions, also while they '
      'load', () async {
    fakeMediaPipe();
    final gate = Completer<void>();
    final model = testModel(
      supportImage: false,
      resolver: GatedResolver(gate.future),
      maxConcurrentSessions: 1,
    );

    final first = model.openSession();
    await _settle();
    await expectLater(model.openSession(), throwsStateError);
    gate.complete();
    final session = await first;
    await expectLater(model.openSession(), throwsStateError);

    await session.close();
    expect(model.sessions, isEmpty);
    final next = await model.openSession();
    expect(model.sessions, [next]);
    // The legacy session does not count.
    await model.createSession();
    await model.close();
  });

  test('a stop on one session does not cancel the call of another', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openSession();
    final b = await model.openSession();
    await a.addQueryChunk(const Message(text: 'QA', isUser: true));
    await b.addQueryChunk(const Message(text: 'QB', isUser: true));

    final aReply = a.getResponse();
    final bReply = b.getResponse();
    await _settle();
    expect(fake.calls, hasLength(1), reason: 'one call at a time');

    await b.stopGeneration();
    expect(fake.cancels, isEmpty, reason: "the running call is a's");
    expect(await bReply, isEmpty);

    fake.calls.single.complete('for a');
    expect(await aReply, 'for a');
    await _settle();
    expect(fake.calls, hasLength(1), reason: 'the stopped call never ran');
    await model.close();
  });

  test('the second session waits for the first one\'s call however long '
      'it runs', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openSession();
    final b = await model.openSession();
    await a.addQueryChunk(const Message(text: 'QA', isUser: true));
    await b.addQueryChunk(const Message(text: 'QB', isUser: true));

    final aReply = a.getResponse();
    final bReply = b.getResponse();
    await _settle();
    fake.calls.single.complete('A');
    expect(await aReply, 'A');
    await _settle();
    expect(fake.calls, hasLength(2));
    expect(_prompt(fake.prompts.last), contains('QB'));
    fake.calls.last.complete('B');
    expect(await bReply, 'B');
    await model.close();
  });

  test('a stop on the session whose call runs cancels it in '
      'MediaPipe', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openSession();
    await a.addQueryChunk(_hi);
    unawaited(a.getResponse());
    await _settle();
    await a.stopGeneration();
    expect(fake.cancels, hasLength(1));
    fake.calls.single.complete('');
    await model.close();
  });

  test('closing the model closes every open session', () async {
    fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openSession();
    final b = await model.openSession();
    await model.close();
    expect(model.sessions, isEmpty);
    for (final session in [a, b]) {
      await expectLater(session.addQueryChunk(_hi), throwsStateError);
    }
    await expectLater(model.openSession(), throwsStateError);
  });

  test('a model closed while an open session loads hands it out to nobody '
      'and releases its LlmInference', () async {
    final fake = fakeMediaPipe();
    final gate = Completer<void>();
    final model = testModel(
      supportImage: false,
      resolver: GatedResolver(gate.future),
    );
    final opening = expectLater(model.openSession(), throwsStateError);
    await _settle();
    final closing = model.close();
    gate.complete();
    await closing;
    await opening;
    expect(model.sessions, isEmpty);
    expect(fake.closed, hasLength(fake.created.length));
  });

  test('openChat takes the model\'s own type unless one is passed', () async {
    fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final own = await model.openChat();
    final passed = await model.openChat(modelType: ModelType.qwen);
    expect(own.modelType, ModelType.gemma4);
    expect(passed.modelType, ModelType.qwen);
    await own.close();
    await passed.close();
    await model.close();
  });

  test('sizeInTokens waits for the calls in MediaPipe, which refuses it '
      'while one runs', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openSession();
    final b = await model.openSession();
    await a.addQueryChunk(const Message(text: 'QA', isUser: true));
    await b.addQueryChunk(const Message(text: 'QB', isUser: true));
    // Two calls in flight, and a count behind them.
    final aReply = a.getResponse();
    final bReply = b.getResponse();
    final size = a.sizeInTokens('four');
    await _settle();
    expect(fake.calls, hasLength(1));

    fake.calls.single.complete('A');
    await _settle();
    expect(fake.calls, hasLength(2));
    fake.calls.last.complete('B');
    expect(await size, 4);
    expect(await aReply, 'A');
    expect(await bReply, 'B');
    await model.close();
  });

  test('two chats that stream at once both end without a busy '
      'error', () async {
    final fake = busyMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openChat();
    final b = await model.openChat();
    await a.addQueryChunk(const Message(text: 'QA', isUser: true));
    await b.addQueryChunk(const Message(text: 'QB', isUser: true));
    // No await between the two: both turns are in flight together, and each
    // chat counts its reply when its stream ends.
    final replies = await Future.wait([
      a.generateChatResponseAsync().toList(),
      b.generateChatResponseAsync().toList(),
    ]);
    expect(fake.errors, isEmpty);
    for (final reply in replies) {
      expect(reply.whereType<TextResponse>().map((r) => r.token).join(), 'ok');
    }
    expect(fake.prompts, hasLength(2));
    await a.close();
    await b.close();
    await model.close();
  });

  test('a later session that asks for another sampling is told once', () async {
    fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final lines = await _printed(() async {
      await model.openSession();
      // Unset on both sides: the family defaults again, nothing to say.
      await model.openSession();
      await model.openSession(temperature: 0, topK: 1);
      await model.openSession(temperature: 0.3);
    });
    final warnings = _warnings(lines);
    expect(warnings, hasLength(1), reason: lines.join('\n'));
    // Greedy reaches MediaPipe as topK 1 (temperature 0 is sent as 1).
    expect(warnings.single, contains('topK 1,'));
    expect(warnings.single, contains('loaded with temperature'));
    expect(warnings.single, contains('topK 40'));
    await model.close();
  });

  test('a later session that asks for another LoRA is told', () async {
    fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final lines = await _printed(() async {
      await model.openSession();
      await model.openSession(loraPath: 'blob:lora');
    });
    final warnings = _warnings(lines);
    expect(warnings, hasLength(1), reason: lines.join('\n'));
    expect(warnings.single, contains('LoRA blob:lora'));
    expect(warnings.single, contains('no LoRA'));
    await model.close();
  });

  test('a closed legacy session leaves sessions; a replaced one does not '
      'take the new one with it', () async {
    fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final first = await model.createSession();
    final second = await model.createSession();
    expect(model.sessions, [second], reason: 'first was closed by second');
    await first.close();
    expect(model.sessions, [second]);
    await second.close();
    expect(model.sessions, isEmpty);
    await model.close();
  });

  test('openChat takes the model\'s image and audio support', () async {
    fakeMediaPipe();
    final model = testModel(
      supportImage: true,
      supportAudio: true,
      resolver: BlobResolver(),
    );
    final own = await model.openChat();
    final off = await model.openChat(supportImage: false, supportAudio: false);
    expect(own.supportImage, isTrue);
    expect(own.supportAudio, isTrue);
    expect(off.supportImage, isFalse);
    expect(off.supportAudio, isFalse);
    await own.close();
    await off.close();
    await model.close();
  });

  test('a closed model loads no LlmInference for openSession', () async {
    final fake = fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    await model.close();
    await expectLater(model.openSession(), throwsStateError);
    expect(fake.created, isEmpty);
  });

  test('a failed load frees its place under the cap', () async {
    final fake = fakeMediaPipe();
    final model = testModel(
      supportImage: false,
      resolver: FlakyResolver(1),
      maxConcurrentSessions: 1,
    );
    await expectLater(model.openSession(), throwsStateError);
    final session = await model.openSession();
    expect(model.sessions, [session]);
    expect(fake.created, hasLength(1));
    await model.close();
  });

  test('the legacy session does not count against the cap', () async {
    fakeMediaPipe();
    final model = testModel(
      supportImage: false,
      resolver: BlobResolver(),
      maxConcurrentSessions: 1,
    );
    final legacy = await model.createSession();
    final open = await model.openSession();
    expect(model.sessions, [legacy, open]);
    await model.close();
  });

  test('a blocking call closed while it waits for another session\'s call '
      'throws StateError', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openSession();
    final b = await model.openSession();
    await a.addQueryChunk(const Message(text: 'QA', isUser: true));
    await b.addQueryChunk(const Message(text: 'QB', isUser: true));
    final aReply = a.getResponse();
    final bReply = expectLater(b.getResponse(), throwsStateError);
    await _settle();
    await b.close();
    await bReply;
    fake.calls.single.complete('A');
    expect(await aReply, 'A');
    await model.close();
  });

  test('a chat whose reply ended does not wait for the other chat\'s '
      'generation to count it', () async {
    final fake = heldMediaPipe(streamReplies: true);
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openChat();
    final b = await model.openChat();
    await a.addQueryChunk(const Message(text: 'QA', isUser: true));
    await b.addQueryChunk(const Message(text: 'QB', isUser: true));
    final aTurn = a.generateChatResponseAsync().toList();
    final bTurn = b.generateChatResponseAsync().toList();
    await _settle();
    expect(fake.calls, hasLength(1));

    fake.calls.single.complete('Reply A');
    await _settle();
    expect(fake.calls, hasLength(2), reason: "b's generation runs now");
    // a's stream has ended and the chat counts the reply; MediaPipe is busy
    // with b's call, so the count comes from a's own call.
    final aReplies = await aTurn.timeout(const Duration(seconds: 2));
    expect(
      aReplies.whereType<TextResponse>().map((r) => r.token).join(),
      'Reply A',
    );
    // An empty text costs no call either: a stopped turn's reply.
    expect(
      await model.sessions.first
          .sizeInTokens('')
          .timeout(const Duration(seconds: 2)),
      0,
    );
    expect(fake.calls.last.isCompleted, isFalse);

    fake.calls.last.complete('Reply B');
    await bTurn;
    await a.close();
    await b.close();
    await model.close();
  });

  test('a chat stopped while its call runs counts its partial reply when '
      'that call ends, not after the other chat\'s generation', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openChat();
    final b = await model.openChat();
    await a.addQueryChunk(const Message(text: 'QA', isUser: true));
    await b.addQueryChunk(const Message(text: 'QB', isUser: true));
    final aTurn = a.generateChatResponseAsync().toList();
    final bTurn = b.generateChatResponseAsync().toList();
    await _settle();
    expect(fake.calls, hasLength(1));
    fake.progress.single!.callAsFunction(null, 'par'.toJS, false.toJS);
    await _settle();

    // a's stream ends at the stop; its call settles a moment later.
    await a.stopGeneration();
    expect(fake.cancels, hasLength(1));
    await _settle();
    fake.calls.single.complete('partial');
    await _settle();
    expect(fake.calls, hasLength(2), reason: "b's generation runs now");

    final aReplies = await aTurn.timeout(const Duration(seconds: 2));
    expect(
      aReplies.whereType<TextResponse>().map((r) => r.token).join(),
      'par',
    );
    expect(fake.calls.last.isCompleted, isFalse);

    fake.calls.last.complete('Reply B');
    await bTurn;
    await a.close();
    await b.close();
    await model.close();
  });

  test('a token count still queued when the model closes fails and never '
      'reaches the closed LlmInference', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final a = await model.openSession();
    await a.addQueryChunk(const Message(text: 'QA', isUser: true));
    unawaited(a.getResponse().then<void>((_) {}, onError: (_) {}));
    await _settle();
    final count = expectLater(a.sizeInTokens('not cached'), throwsStateError);
    await _settle();

    await model.close();
    await count.timeout(const Duration(seconds: 2));
    fake.calls.single.complete('late');
    await _settle();
    expect(fake.sizes, isEmpty);
    await expectLater(a.sizeInTokens('later'), throwsStateError);
  });

  test('the LoRA warning compares with the LoRA the model applied', () async {
    fakeMediaPipe();
    final model = testModel(
      supportImage: false,
      resolver: LoraResolver('blob:installed'),
      loraRanks: [4],
    );
    final lines = await _printed(() async {
      await model.openSession();
      // The installed LoRA is the one applied: asking for it again is fine.
      await model.openSession(loraPath: 'blob:installed');
      await model.openSession(loraPath: 'blob:other');
    });
    final warnings = _warnings(lines);
    expect(warnings, hasLength(1), reason: lines.join('\n'));
    expect(warnings.single, contains('LoRA blob:other'));
    expect(warnings.single, contains('loaded with LoRA blob:installed'));
    await model.close();
  });

  test('a LoRA without loraRanks is not applied, and the warning says '
      'so', () async {
    fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final lines = await _printed(() async {
      await model.openSession(loraPath: 'blob:lora');
      await model.openSession(loraPath: 'blob:lora');
    });
    final warnings = _warnings(lines);
    expect(warnings, hasLength(1), reason: lines.join('\n'));
    expect(warnings.single, contains('loaded with no LoRA'));
    await model.close();
  });

  test('openChat runs a chat on its own session', () async {
    final fake = fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final first = await model.openChat();
    final second = await model.openChat();
    await first.addQueryChunk(_hi);
    // The fake answers the call but streams no piece, so the chat's reply is
    // empty; what is checked is that its prompt reached the model.
    await first.generateChatResponse();
    expect(_prompt(fake.prompts.single), contains('Hi'));
    expect(model.sessions, hasLength(2));
    await first.close();
    await second.close();
    expect(model.sessions, isEmpty);
    await model.close();
  });
}
