// Fake-backed unit tests for OnnxSession — zero dlopen (hardened plan
// Phase 3, Task 6).
import 'dart:typed_data';

import 'package:flutter_gemma/core/message.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma_onnx/src/onnx_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_gen_ai_client.dart';

OnnxSession _session(
  FakeGenAiClient client, {
  String? systemInstruction,
  int? maxOutputTokens,
  VoidCallback? onClose,
}) {
  return OnnxSession(
    client: client,
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.onnx,
    systemInstruction: systemInstruction,
    maxOutputTokens: maxOutputTokens,
    onClose: onClose ?? () {},
  );
}

typedef VoidCallback = void Function();

void main() {
  group('streaming', () {
    test('getResponseAsync yields chunks in fake-emission order', () async {
      final client = FakeGenAiClient(chunksToEmit: ['Hel', 'lo, ', 'world!']);
      final session = _session(client);
      await session.addQueryChunk(const Message(text: 'hi', isUser: true));

      final chunks = await session.getResponseAsync().toList();

      expect(chunks, ['Hel', 'lo, ', 'world!']);
    });

    test(
      'getResponse equals the concatenation of the streamed chunks',
      () async {
        final client = FakeGenAiClient(chunksToEmit: ['Hel', 'lo, ', 'world!']);
        final session = _session(client);
        await session.addQueryChunk(const Message(text: 'hi', isUser: true));

        final full = await session.getResponse();

        expect(
          full,
          'Hel'
          'lo, '
          'world!',
        );
      },
    );
  });

  group('addQueryChunk buffering', () {
    test(
      'two chunks become one generate() call with concatenated content',
      () async {
        final client = FakeGenAiClient(chunksToEmit: ['ok']);
        final session = _session(client);

        await session.addQueryChunk(
          const Message(text: 'Hello ', isUser: true),
        );
        await session.addQueryChunk(const Message(text: 'world', isUser: true));
        await session.getResponse();

        expect(client.generateCalls, hasLength(1));
        expect(client.generateCalls.single.userContent, 'Hello world');
      },
    );

    test('buffer is cleared after drain — next turn starts empty', () async {
      final client = FakeGenAiClient(chunksToEmit: ['ok']);
      final session = _session(client);

      await session.addQueryChunk(const Message(text: 'first', isUser: true));
      await session.getResponse();
      await session.getResponse(); // no new addQueryChunk in between

      expect(client.generateCalls, hasLength(2));
      expect(client.generateCalls[0].userContent, 'first');
      expect(client.generateCalls[1].userContent, '');
    });

    test('first turn carries systemInstruction; later turns do not', () async {
      final client = FakeGenAiClient(chunksToEmit: ['ok']);
      final session = _session(client, systemInstruction: 'Be terse.');

      await session.addQueryChunk(const Message(text: 'one', isUser: true));
      await session.getResponse();
      await session.addQueryChunk(const Message(text: 'two', isUser: true));
      await session.getResponse();

      expect(client.generateCalls[0].isFirstTurn, isTrue);
      expect(client.generateCalls[0].systemInstruction, 'Be terse.');
      expect(client.generateCalls[1].isFirstTurn, isFalse);
      expect(client.generateCalls[1].systemInstruction, isNull);
    });

    test('systemInstruction is RE-SENT on the post-stop reset turn — not '
        'dropped for the rest of the conversation', () async {
      final client = FakeGenAiClient(chunksToEmit: ['a', 'b', 'c', 'd']);
      final session = _session(client, systemInstruction: 'Be terse.');

      // Turn 1: natural first turn.
      await session.addQueryChunk(const Message(text: 'one', isUser: true));
      await session.getResponse();
      expect(client.generateCalls[0].systemInstruction, 'Be terse.');

      // Turn 2: stopped mid-stream.
      await session.addQueryChunk(const Message(text: 'two', isUser: true));
      var count = 0;
      await for (final _ in session.getResponseAsync()) {
        count++;
        if (count == 1) await session.stopGeneration();
      }
      expect(client.generateCalls[1].systemInstruction, isNull);

      // Turn 3: forced reset (fresh generator, empty KV) — the system
      // instruction MUST be re-sent, or the model silently loses it.
      await session.addQueryChunk(const Message(text: 'three', isUser: true));
      await session.getResponse();
      expect(client.generateCalls[2].isFirstTurn, isTrue);
      expect(client.generateCalls[2].systemInstruction, 'Be terse.');

      // Turn 4: back to normal — no forced reset, no system instruction.
      await session.addQueryChunk(const Message(text: 'four', isUser: true));
      await session.getResponse();
      expect(client.generateCalls[3].isFirstTurn, isFalse);
      expect(client.generateCalls[3].systemInstruction, isNull);
    });
  });

  group('stopGeneration', () {
    test(
      'mid-stream stop ends the stream early; session stays usable',
      () async {
        final client = FakeGenAiClient(chunksToEmit: ['a', 'b', 'c', 'd']);
        final session = _session(client);
        await session.addQueryChunk(const Message(text: 'hi', isUser: true));

        final received = <String>[];
        await for (final chunk in session.getResponseAsync()) {
          received.add(chunk);
          if (received.length == 1) {
            await session.stopGeneration();
          }
        }

        expect(client.stopGenerationCalls, 1);
        expect(received.length, lessThan(4));

        // Session is usable for the next turn — a fresh generate() isn't
        // permanently wedged by the earlier stop flag.
        await session.addQueryChunk(const Message(text: 'again', isUser: true));
        final next = await session.getResponse();
        expect(next, 'abcd');
      },
    );

    test('a stopped turn forces the NEXT turn to start a fresh generator '
        '(no KV-cache-dangling-turn bleed — see host smoke finding)', () async {
      final client = FakeGenAiClient(chunksToEmit: ['a', 'b', 'c', 'd']);
      final session = _session(client);

      // Turn 1: the natural first turn.
      await session.addQueryChunk(const Message(text: 'one', isUser: true));
      await session.getResponse();
      expect(client.generateCalls[0].isFirstTurn, isTrue);

      // Turn 2: stopped mid-stream.
      await session.addQueryChunk(const Message(text: 'two', isUser: true));
      var count = 0;
      await for (final _ in session.getResponseAsync()) {
        count++;
        if (count == 1) await session.stopGeneration();
      }
      expect(client.generateCalls[1].isFirstTurn, isFalse);

      // Turn 3: MUST start fresh — turn 2 left a dangling, incomplete
      // assistant turn in the KV cache that would otherwise bleed into
      // turn 3's continuation.
      await session.addQueryChunk(const Message(text: 'three', isUser: true));
      await session.getResponse();
      expect(client.generateCalls[2].isFirstTurn, isTrue);

      // Turn 4: back to normal (no forced reset without a stop).
      await session.addQueryChunk(const Message(text: 'four', isUser: true));
      await session.getResponse();
      expect(client.generateCalls[3].isFirstTurn, isFalse);
    });
  });

  group('barge-in / mid-stream error force a reset', () {
    test(
      'consumer cancelling the stream (barge-in, no explicit stopGeneration) '
      'forces the NEXT turn to start a fresh generator',
      () async {
        final client = FakeGenAiClient(chunksToEmit: ['a', 'b', 'c', 'd']);
        final session = _session(client);

        // Turn 1: natural first turn.
        await session.addQueryChunk(const Message(text: 'one', isUser: true));
        await session.getResponse();
        expect(client.generateCalls[0].isFirstTurn, isTrue);

        // Turn 2: consumer breaks out of the stream mid-generation WITHOUT
        // calling session.stopGeneration() — the barge-in path (e.g. a
        // voice-loop interrupt cancelling its subscription).
        await session.addQueryChunk(const Message(text: 'two', isUser: true));
        var count = 0;
        await for (final _ in session.getResponseAsync()) {
          count++;
          if (count == 1) break;
        }
        expect(client.stopGenerationCalls, 0);

        // Turn 3: MUST start fresh — the cancelled turn left a dangling,
        // incomplete assistant turn in the KV cache just like an explicit
        // stop would.
        await session.addQueryChunk(const Message(text: 'three', isUser: true));
        await session.getResponse();
        expect(client.generateCalls[2].isFirstTurn, isTrue);
      },
    );

    test('a mid-stream native generate() error forces the NEXT turn to start '
        'a fresh generator', () async {
      final client = FakeGenAiClient(chunksToEmit: ['a', 'b']);
      final session = _session(client);

      // Turn 1: natural first turn.
      await session.addQueryChunk(const Message(text: 'one', isUser: true));
      await session.getResponse();
      expect(client.generateCalls[0].isFirstTurn, isTrue);

      // Turn 2: the native worker fails mid-stream.
      client.generateError = StateError('native GenerateError');
      await session.addQueryChunk(const Message(text: 'two', isUser: true));
      await expectLater(
        () => session.getResponse(),
        throwsA(isA<StateError>()),
      );

      // Turn 3: MUST start fresh — the errored turn must not leave a
      // dangling assistant turn behind for the next generator to inherit.
      client.generateError = null;
      await session.addQueryChunk(const Message(text: 'three', isUser: true));
      await session.getResponse();
      expect(client.generateCalls[2].isFirstTurn, isTrue);
    });
  });

  group('close', () {
    test('is idempotent', () async {
      final client = FakeGenAiClient();
      var closeCount = 0;
      final session = _session(client, onClose: () => closeCount++);

      await session.close();
      await session.close();

      expect(closeCount, 1);
      expect(client.resetSessionCalls, 1);
    });

    test('close-then-call throws StateError', () async {
      final client = FakeGenAiClient();
      final session = _session(client);
      await session.close();

      expect(
        () => session.addQueryChunk(const Message(text: 'x', isUser: true)),
        throwsStateError,
      );
      expect(() => session.getResponse(), throwsStateError);
    });
  });

  group('unsupported input', () {
    test('image Message throws UnsupportedError', () async {
      final client = FakeGenAiClient();
      final session = _session(client);

      expect(
        () => session.addQueryChunk(
          Message(
            text: 'look',
            isUser: true,
            imageBytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('audio Message throws UnsupportedError', () async {
      final client = FakeGenAiClient();
      final session = _session(client);

      expect(
        () => session.addQueryChunk(
          Message(
            text: 'listen',
            isUser: true,
            audioBytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('sizeInTokens / getSessionMetrics', () {
    test('sizeInTokens delegates to client.countTokens', () async {
      final client = FakeGenAiClient();
      final session = _session(client);

      final count = await session.sizeInTokens('abcdefgh');

      expect(client.countTokensCalls, ['abcdefgh']);
      expect(count, 2); // fake: ceil(length / 4)
    });

    test('getSessionMetrics is empty before any generation', () {
      final client = FakeGenAiClient();
      final session = _session(client);

      final metrics = session.getSessionMetrics();

      expect(metrics.inputTokens, 0);
      expect(metrics.outputTokens, 0);
    });

    test('getSessionMetrics reflects the last generate() call', () async {
      final client = FakeGenAiClient(chunksToEmit: ['a', 'b', 'c']);
      final session = _session(client);
      await session.addQueryChunk(const Message(text: 'hi', isUser: true));
      await session.getResponse();

      final metrics = session.getSessionMetrics();

      expect(metrics.outputTokens, 3);
    });
  });
}
