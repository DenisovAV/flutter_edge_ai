import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_gemma_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_gemma_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [ConversationHandle] that echoes scripted responses without touching
/// native code. Each fake owns its own response script, so two fakes model
/// two isolated conversations — exactly the property multi-session must
/// preserve. Mirrors the injectable-fake pattern from
/// `backend_preference_test.dart` (PR #288).
class _FakeConversationHandle implements ConversationHandle {
  _FakeConversationHandle(this._scriptedChunks);

  /// Chunks this handle yields on each chat()/chatRaw() call.
  final List<String> _scriptedChunks;

  bool isClosed = false;
  int cancelCount = 0;

  /// Text staged through chat()/chatRaw() — a role-user message.
  final List<String> sentTexts = [];

  /// Prebuilt messages sent through chatRawMessage() — how tool results go.
  final List<String> sentMessages = [];

  /// No engine on the host VM, so no tokenizer. Null is the honest answer and
  /// the one sizeInTokens is written to handle — returning a made-up number
  /// here would hide exactly the defect this method was added to fix.
  @override
  Future<int?> tokenCount(String text) async => null;

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) async* {
    sentTexts.add(text);
    for (final c in _scriptedChunks) {
      yield c;
    }
  }

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) async* {
    sentTexts.add(text);
    // Raw chunks are full JSON documents in the real path; the fake yields
    // OpenAI-shaped text-content JSON so SdkTextExtractor can pull text out.
    for (final c in _scriptedChunks) {
      yield '{"role":"assistant","content":[{"type":"text","text":"$c"}]}';
    }
  }

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
  }) async* {
    sentMessages.add(messageJson);
    for (final c in _scriptedChunks) {
      yield '{"role":"assistant","content":[{"type":"text","text":"$c"}]}';
    }
  }

  @override
  void cancelGeneration() => cancelCount++;

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  void close() => isClosed = true;
}

void main() {
  group('FfiInferenceModelSession with fake handle', () {
    test('routes getResponse through its own handle (non-Gemma4)', () async {
      final handle = _FakeConversationHandle(['Hello', ' world']);
      final session = FfiInferenceModelSession(
        handle: handle,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
        supportImage: false,
        supportAudio: false,
        onClose: () {},
      );

      await session.addQueryChunk(const Message(text: 'hi', isUser: true));
      final response = await session.getResponse();

      expect(response, 'Hello world');
      // Non-Gemma4 path keeps the raw cache null.
      expect(session.lastRawResponse, isNull);
    });

    test('captures raw response for Gemma 4 tool-call path', () async {
      final handle = _FakeConversationHandle(['Hi']);
      final session = FfiInferenceModelSession(
        handle: handle,
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
        supportImage: false,
        supportAudio: false,
        onClose: () {},
      );

      await session.addQueryChunk(const Message(text: 'hi', isUser: true));
      final response = await session.getResponse();

      // Text extracted from the JSON chunk.
      expect(response, 'Hi');
      // Raw JSON captured so chat.dart can run extractToolCalls.
      expect(session.lastRawResponse, contains('"type":"text"'));
      expect(session.lastRawResponse, contains('Hi'));
    });

    FfiInferenceModelSession nativeToolSession(
      _FakeConversationHandle handle, {
      ModelType modelType = ModelType.functionGemma,
    }) => FfiInferenceModelSession(
      handle: handle,
      modelType: modelType,
      fileType: ModelFileType.litertlm,
      supportImage: false,
      supportAudio: false,
      onClose: () {},
    );

    for (final modelType in [ModelType.functionGemma, ModelType.gemma4]) {
      test(
        '$modelType: a turn of tool results goes back as one role-tool message',
        () async {
          final handle = _FakeConversationHandle(['7006652']);
          final session = nativeToolSession(handle, modelType: modelType);

          await session.addQueryChunk(
            Message.toolResponse(
              toolName: 'multiply',
              response: {'result': 7006652},
            ),
          );
          await session.addQueryChunk(
            Message.toolResponse(
              toolName: 'get_time',
              response: {'time': '12:00'},
            ),
          );
          final response = await session.getResponse();

          expect(response, '7006652');
          expect(
            handle.sentTexts,
            isEmpty,
            reason:
                'as a user message the model opens a new turn and calls the '
                'same function again',
          );
          final message =
              jsonDecode(handle.sentMessages.single) as Map<String, dynamic>;
          expect(message['role'], 'tool');
          expect(message['content'], [
            {
              'type': 'tool_response',
              'name': 'multiply',
              'response': {'result': 7006652},
            },
            {
              'type': 'tool_response',
              'name': 'get_time',
              'response': {'time': '12:00'},
            },
          ]);
          expect(session.lastRawResponse, contains('7006652'));
        },
      );
    }

    test('streaming sends tool results the same way', () async {
      final handle = _FakeConversationHandle(['done']);
      final session = nativeToolSession(handle);

      await session.addQueryChunk(
        Message.toolResponse(toolName: 'show_alert', response: {'ok': true}),
      );
      final response = await session.getResponseAsync().join();

      expect(response, 'done');
      expect(handle.sentTexts, isEmpty);
      expect((jsonDecode(handle.sentMessages.single) as Map)['role'], 'tool');
    });

    test(
      'tool results staged with user text stay in the user message',
      () async {
        final handle = _FakeConversationHandle(['ok']);
        final session = nativeToolSession(handle);

        await session.addQueryChunk(
          Message.toolResponse(toolName: 'multiply', response: {'result': 1}),
        );
        await session.addQueryChunk(
          const Message(text: 'and now?', isUser: true),
        );
        await session.getResponse();

        expect(handle.sentMessages, isEmpty);
        expect(handle.sentTexts.single, contains('and now?'));
        expect(handle.sentTexts.single, contains('multiply'));
      },
    );

    test('the next turn starts clean after tool results were sent', () async {
      final handle = _FakeConversationHandle(['ok']);
      final session = nativeToolSession(handle);

      await session.addQueryChunk(
        Message.toolResponse(toolName: 'multiply', response: {'result': 1}),
      );
      await session.getResponse();
      await session.addQueryChunk(const Message(text: 'thanks', isUser: true));
      await session.getResponse();

      expect(handle.sentMessages, hasLength(1));
      expect(handle.sentTexts.single, 'thanks');
    });

    test('a tool response without toolName is rejected', () {
      final session = nativeToolSession(_FakeConversationHandle(['x']));
      expect(
        () => session.addQueryChunk(
          const Message(
            text: '{}',
            isUser: true,
            type: MessageType.toolResponse,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a model without native tools keeps tool results in text', () async {
      final handle = _FakeConversationHandle(['ok']);
      final session = FfiInferenceModelSession(
        handle: handle,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
        supportImage: false,
        supportAudio: false,
        onClose: () {},
      );

      await session.addQueryChunk(
        Message.toolResponse(toolName: 'multiply', response: {'result': 1}),
      );
      await session.getResponse();

      expect(handle.sentMessages, isEmpty);
      expect(handle.sentTexts.single, contains('multiply'));
    });

    test(
      'two sessions with distinct handles produce isolated outputs',
      () async {
        final handleA = _FakeConversationHandle(['I am A']);
        final handleB = _FakeConversationHandle(['I am B']);

        final sessionA = FfiInferenceModelSession(
          handle: handleA,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
          supportImage: false,
          supportAudio: false,
          onClose: () {},
        );
        final sessionB = FfiInferenceModelSession(
          handle: handleB,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
          supportImage: false,
          supportAudio: false,
          onClose: () {},
        );

        await sessionA.addQueryChunk(const Message(text: 'q', isUser: true));
        await sessionB.addQueryChunk(const Message(text: 'q', isUser: true));

        final respA = await sessionA.getResponse();
        final respB = await sessionB.getResponse();

        expect(respA, 'I am A');
        expect(respB, 'I am B');
      },
    );

    test(
      'close() closes only this session\'s handle and fires onClose',
      () async {
        final handleA = _FakeConversationHandle(['a']);
        final handleB = _FakeConversationHandle(['b']);
        var onCloseACalled = false;

        final sessionA = FfiInferenceModelSession(
          handle: handleA,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
          supportImage: false,
          supportAudio: false,
          onClose: () => onCloseACalled = true,
        );
        final sessionB = FfiInferenceModelSession(
          handle: handleB,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
          supportImage: false,
          supportAudio: false,
          onClose: () {},
        );

        await sessionA.close();

        expect(handleA.isClosed, isTrue);
        expect(handleB.isClosed, isFalse, reason: 'B must survive A.close()');
        expect(onCloseACalled, isTrue);
        // B is still usable after A closed.
        await sessionB.addQueryChunk(const Message(text: 'q', isUser: true));
        expect(await sessionB.getResponse(), 'b');
      },
    );

    test('methods throw StateError after close', () async {
      final session = FfiInferenceModelSession(
        handle: _FakeConversationHandle(['x']),
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
        supportImage: false,
        supportAudio: false,
        onClose: () {},
      );

      await session.close();

      expect(
        () => session.addQueryChunk(const Message(text: 'q', isUser: true)),
        throwsStateError,
      );
    });

    test('stopGeneration cancels via the handle', () async {
      final handle = _FakeConversationHandle(['x']);
      final session = FfiInferenceModelSession(
        handle: handle,
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
        supportImage: false,
        supportAudio: false,
        onClose: () {},
      );

      await session.stopGeneration();

      expect(handle.cancelCount, 1);
    });
  });

  group('FfiInferenceModel maxConcurrentSessions cap', () {
    test('openSession throws StateError when cap is reached', () async {
      // cap=0 means the very first openSession exceeds the cap. The check
      // runs before any native call, so a bare (uninitialized) client never
      // gets touched. Proves the cap gates openSession.
      final model = FfiInferenceModel(
        ffiClient: LiteRtLmFfiClient(),
        maxTokens: 256,
        modelType: ModelType.gemmaIt,
        activeBackend: null,
        maxConcurrentSessions: 0,
        onClose: () {},
      );

      await expectLater(
        model.openSession(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Max concurrent sessions (0)'),
          ),
        ),
      );
    });

    test('null cap imposes no limit on openSession gate', () {
      // With no cap, the cap check never trips. We can't drive the native
      // path here, but constructing with a null cap and reading the field
      // confirms the default is unlimited (backward-compatible).
      final model = FfiInferenceModel(
        ffiClient: LiteRtLmFfiClient(),
        maxTokens: 256,
        modelType: ModelType.gemmaIt,
        activeBackend: null,
        onClose: () {},
      );

      expect(model.maxConcurrentSessions, isNull);
    });
  });

  group('sizeInTokens', () {
    FfiInferenceModelSession sessionWith(ConversationHandle handle) =>
        FfiInferenceModelSession(
          handle: handle,
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
          supportImage: false,
          supportAudio: false,
          onClose: () {},
        );

    test(
      'returns the tokenizer count verbatim when the handle answers',
      () async {
        // 7 for a 40-char string is nothing the estimator could produce from
        // either divisor — the point is to prove the native count is passed
        // through, not recomputed. Before this, both branches were untested and
        // an integration assert of `n > 0` passed identically for the estimate.
        final session = sessionWith(_CountingHandle(7));
        expect(await session.sizeInTokens('x' * 40), 7);
      },
    );

    test(
      'falls back to a conservative estimate when the handle returns null',
      () async {
        // 2 chars/token, not 4. Undercounting overruns the native KV cache
        // (#318); overcounting only trims history early. The old 4 was measured
        // at 0.44x on Chinese, i.e. wrong in the crash direction.
        final session = sessionWith(_FakeConversationHandle(const []));
        expect(await session.sizeInTokens('x' * 40), 20);
      },
    );

    test('throws after close, like every other session method', () async {
      final session = sessionWith(_CountingHandle(7));
      await session.close();
      expect(() => session.sizeInTokens('hello'), throwsStateError);
    });
  });
}

/// Handle that reports a fixed token count, standing in for a live tokenizer.
class _CountingHandle extends _FakeConversationHandle {
  _CountingHandle(this._count) : super(const []);
  final int _count;

  @override
  Future<int?> tokenCount(String text) async => _count;
}
