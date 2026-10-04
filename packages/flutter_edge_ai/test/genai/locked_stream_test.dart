import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/genai.dart';
import 'package:flutter_test/flutter_test.dart';

/// A no-engine [InferenceChat] whose staging (addQueryChunk) and generation
/// (generateChatResponseAsync) are driven by the test, so `_lockedStream`'s
/// mutex/cancel state machine can be exercised deterministically.
class _FakeChat extends InferenceChat {
  _FakeChat() : super(sessionCreator: null, maxTokens: 1024);

  Duration stageDelay = Duration.zero;
  bool throwOnStage = false;
  final staged = <String>[];
  int stopGenerationCalls = 0;
  StreamController<ModelResponse>? lastGen;

  @override
  Future<void> addQueryChunk(
    Message message, [
    bool noTool = false,
    bool prefix = false,
  ]) async {
    if (stageDelay > Duration.zero) await Future<void>.delayed(stageDelay);
    if (throwOnStage) throw StateError('stage boom');
    staged.add(message.text);
  }

  @override
  Stream<ModelResponse> generateChatResponseAsync() {
    final c = StreamController<ModelResponse>();
    lastGen = c;
    return c.stream;
  }

  @override
  Future<void> stopGeneration() async {
    stopGenerationCalls++;
  }
}

String _text(ChatMessage m) =>
    m.parts.whereType<TextPart>().map((p) => p.text).join();

void main() {
  test(
    'cancel during stage keeps the lock held until stage() finishes',
    () async {
      // The C1 bug: onCancel releases the mutex mid-stage, while stage() is still
      // mutating shared session state — so a second turn can interleave.
      final chat = _FakeChat()..stageDelay = const Duration(milliseconds: 120);
      final sub = chat.sendMessageStream(ChatMessage.user('hi')).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.genaiLock.isLocked, isTrue, reason: 'lock held during stage');

      await sub.cancel(); // cancel while stage() still has ~100ms to run
      expect(
        chat.genaiLock.isLocked,
        isTrue,
        reason: 'lock must NOT be released mid-stage',
      );

      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(
        chat.genaiLock.isLocked,
        isFalse,
        reason: 'lock released once stage() completes',
      );
    },
  );

  test(
    'a queued turn cancelled before acquiring never stages (no lock theft)',
    () async {
      // C1 variant: a stream cancelled while queued on acquire() must not
      // release() the lock the running turn owns. If it did, this turn would be
      // granted the stolen lock and proceed to stage() — an empty `staged`
      // proves it stayed queued and never ran a critical section.
      final chat = _FakeChat();
      await chat.genaiLock
          .acquire(); // turn A holds the lock, does nothing else

      final sub = chat.sendMessageStream(ChatMessage.user('B')).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20)); // B queued
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        chat.staged,
        isEmpty,
        reason: 'a queued+cancelled turn must not steal the lock and stage',
      );
      expect(chat.genaiLock.isLocked, isTrue, reason: 'A still holds the lock');
    },
  );

  test(
    'normal completion yields mapped chunks and releases the lock',
    () async {
      final chat = _FakeChat();
      final chunks = <ChatMessage>[];
      final done = Completer<void>();
      chat
          .sendMessageStream(ChatMessage.user('hi'))
          .listen(chunks.add, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      chat.lastGen!.add(const TextResponse('a'));
      chat.lastGen!.add(const TextResponse('b'));
      await chat.lastGen!.close();
      await done.future;

      expect(chunks.map(_text).toList(), ['a', 'b']);
      expect(chat.genaiLock.isLocked, isFalse, reason: 'lock released on done');
      // Regression: Dart fires onCancel after a normal `done` too; the teardown
      // there must NOT issue a stopGeneration() on the shared session. With the
      // pre-fix `if (generating)` guard this was 1.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        chat.stopGenerationCalls,
        0,
        reason: 'no spurious stopGeneration after a successful stream',
      );
    },
  );

  test('a turn completing does not stop the next back-to-back turn', () async {
    // The race the spurious post-done onCancel opens: turn A's onDone releases
    // the lock, turn B acquires and starts generating on the shared session,
    // THEN A's late onCancel fires stopGeneration() — landing on B.
    final chat = _FakeChat();

    // Turn A: drive to completion.
    final aDone = Completer<void>();
    chat
        .sendMessageStream(ChatMessage.user('A'))
        .listen((_) {}, onDone: aDone.complete);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await chat.lastGen!.close();
    await aDone.future;

    // Turn B: start immediately, keep it live (do not close).
    chat.sendMessageStream(ChatMessage.user('B')).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    chat.lastGen!.add(const TextResponse('b')); // B is generating

    expect(
      chat.stopGenerationCalls,
      0,
      reason: "A's post-completion onCancel must not stop turn B",
    );
  });

  test(
    'error mid-stream forwards it, stops generation, releases the lock',
    () async {
      final chat = _FakeChat();
      Object? err;
      final done = Completer<void>();
      chat
          .sendMessageStream(ChatMessage.user('hi'))
          .listen(
            (_) {},
            onError: (Object e) => err = e,
            onDone: done.complete,
          );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      chat.lastGen!.addError(StateError('boom'));
      await done.future;

      expect(err, isA<StateError>());
      expect(chat.stopGenerationCalls, greaterThan(0));
      expect(
        chat.genaiLock.isLocked,
        isFalse,
        reason: 'lock released on error',
      );
    },
  );

  test('cancel during generation stops it and releases the lock', () async {
    final chat = _FakeChat();
    final sub = chat.sendMessageStream(ChatMessage.user('hi')).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    chat.lastGen!.add(const TextResponse('a')); // generation is live
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await sub.cancel();
    expect(chat.stopGenerationCalls, greaterThan(0));
    expect(chat.genaiLock.isLocked, isFalse, reason: 'lock released on cancel');
  });

  test('stage() throwing forwards the error and releases the lock', () async {
    // The load-bearing pre-generation failure path (an image on a non-vision
    // chat, a LinkPart, a second audio part all throw in _stage). The lock
    // release there is hand-rolled — if it leaked, every future turn would
    // deadlock forever on acquire() with no error surfaced.
    final chat = _FakeChat()..throwOnStage = true;
    Object? err;
    final done = Completer<void>();
    chat
        .sendMessageStream(ChatMessage.user('hi'))
        .listen((_) {}, onError: (Object e) => err = e, onDone: done.complete);
    await done.future;

    expect(err, isA<StateError>(), reason: 'stage error reaches the consumer');
    expect(chat.staged, isEmpty, reason: 'stage threw before staging anything');
    expect(
      chat.genaiLock.isLocked,
      isFalse,
      reason: 'lock released on a stage() throw (no silent deadlock)',
    );
  });
}
