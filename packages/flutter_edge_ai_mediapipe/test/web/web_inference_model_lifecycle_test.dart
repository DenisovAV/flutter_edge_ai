// The web model's lifecycle on fake MediaPipe globals: createSession calls that
// overlap or meet a close(), stops of calls that wait for an earlier one, the
// release of the LlmInference, and the audio the prompt carries.
//
// Browser-only; tool/test_all.sh, and so CI, runs it with --platform chrome:
//   flutter test --platform chrome test/web/web_inference_model_lifecycle_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_media_pipe.dart';

void main() {
  test('two createSession calls at once: the second closes the first, and '
      'only the second stays open', () async {
    fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    final before = await model.createSession();

    final results = await Future.wait([
      model.createSession(),
      model.createSession(),
    ]);

    // Each new session closes the one before it, in the order of the calls.
    for (final closed in [before, results.first]) {
      await expectLater(
        closed.addQueryChunk(const Message(text: 'Hi', isUser: true)),
        throwsStateError,
      );
    }
    await results.last.addQueryChunk(const Message(text: 'Hi', isUser: true));
    expect(model.session, same(results.last));
  });

  test('a stop that arrives while the call waits for the previous one '
      'cancels it before it starts', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());

    final first = await model.createSession();
    await first.addQueryChunk(const Message(text: 'A', isUser: true));
    first.getResponseAsync().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fake.calls, hasLength(1));

    // The next session's call waits for the first one to end.
    final second = await model.createSession();
    await second.addQueryChunk(const Message(text: 'B', isUser: true));
    second.getResponseAsync().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await second.stopGeneration();

    fake.calls.single.complete('done');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fake.calls, hasLength(1), reason: 'the stopped call must not run');
    await model.close();
  });

  test(
    'a closed model loads no LlmInference for a later createSession',
    () async {
      final fake = fakeMediaPipe();
      final model = testModel(supportImage: false, resolver: BlobResolver());
      await model.close();

      await expectLater(model.createSession(), throwsStateError);
      expect(fake.created, isEmpty);
    },
  );

  test('a createSession queued behind a load when the model closes loads '
      'nothing of its own', () async {
    final fake = fakeMediaPipe();
    final gate = Completer<void>();
    final model = testModel(
      supportImage: false,
      resolver: GatedResolver(gate.future),
    );

    final first = expectLater(model.createSession(), throwsStateError);
    final queued = expectLater(model.createSession(), throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final closing = model.close();
    gate.complete();
    await closing;
    await first;
    await queued;
    expect(fake.created, hasLength(1), reason: 'only the first call loads');
    expect(fake.closed, hasLength(1), reason: 'and its model is released');
  });

  test(
    'a session handed out while the model closes is closed with it',
    () async {
      // close() can land at any await of createSession; each step is tried.
      for (var step = 0; step < 12; step++) {
        fakeMediaPipe();
        final model = testModel(supportImage: false, resolver: BlobResolver());
        await model.createSession();
        // A refusal is a right answer too; it is read once close() is done.
        final creating = model.createSession().then<InferenceModelSession?>(
          (session) => session,
          onError: (Object e) => e is StateError ? null : throw e,
        );
        for (var i = 0; i < step; i++) {
          await Future<void>.microtask(() {});
        }
        await model.close();
        final session = await creating;
        if (session == null) continue;
        await expectLater(
          session.addQueryChunk(const Message(text: 'Hi', isUser: true)),
          throwsStateError,
          reason: 'step $step: the session outlived its model',
        );
      }
    },
  );

  test('a blocking call stopped while it waits for the previous one ends '
      'empty, as a stream does', () async {
    final fake = heldMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());

    final first = await model.createSession();
    await first.addQueryChunk(const Message(text: 'A', isUser: true));
    first.getResponseAsync().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fake.calls, hasLength(1));

    final second = await model.createSession();
    await second.addQueryChunk(const Message(text: 'B', isUser: true));
    final reply = second.getResponse();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await second.stopGeneration();

    fake.calls.single.complete('done');
    expect(await reply, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fake.calls, hasLength(1), reason: 'the stopped call must not run');
    await model.close();
  });

  test('close() releases the LlmInference the model loaded', () async {
    final fake = fakeMediaPipe();
    final model = testModel(supportImage: false, resolver: BlobResolver());
    await model.createSession();
    expect(fake.created, hasLength(1));
    expect(fake.closed, isEmpty);
    await model.close();
    expect(fake.closed, hasLength(1));
  });

  test('a model closed while it loads does not hand out a session', () async {
    fakeMediaPipe();
    final gate = Completer<void>();
    final model = testModel(
      supportImage: false,
      resolver: GatedResolver(gate.future),
    );

    final creating = model.createSession();
    final outcome = expectLater(creating, throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // close() waits for the load it finds in flight.
    final closing = model.close();
    gate.complete();
    await closing;
    await outcome;
  });

  test(
    'audio that is a view of a larger buffer is sent in a buffer of its own',
    () async {
      final fake = fakeMediaPipe();
      final model = testModel(
        supportImage: false,
        supportAudio: true,
        resolver: BlobResolver(),
      );
      final buffer = Uint8List.fromList(List.generate(16, (i) => i));
      final view = Uint8List.sublistView(buffer, 4, 12);

      final session = await model.createSession();
      await session.addQueryChunk(
        Message(text: 'What is said?', isUser: true, audioBytes: view),
      );
      await session.getResponse();

      final parts = (fake.prompts.single as JSArray<JSAny>).toDart;
      final audio = parts
          .whereType<JSObject>()
          .where((part) => part.has('audioSource'))
          .single
          .getProperty<JSUint8Array>('audioSource'.toJS)
          .toDart;
      expect(audio, view);
      // Whatever MediaPipe reads, the array or the buffer behind it, holds
      // the audio and nothing else.
      expect(audio.offsetInBytes, 0);
      expect(audio.buffer.lengthInBytes, view.lengthInBytes);
      await model.close();
    },
  );
}
