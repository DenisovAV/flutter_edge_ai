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
