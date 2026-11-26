// The 0.20.0 parity members on the web arm, over the stub `@litert-lm/core`
// (web_runtime_stub.dart): what runs on the runtime (the engine's visual
// token budget, a conversation's clone and token count, ToolChoice.auto, a
// Session) and what is refused by name before it reaches the runtime.
//
// Run: dart test -p chrome test/web/web_parity_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_parity_browser_test.dart
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);

  test(
    "the engine's visual token budget is the runtime's "
    'maxVisionTokensPerImage; without a vision encoder it is refused',
    () async {
      setOnPage('resolvedVisionBackend', backendId('GPU'));
      final engine = await web.createWebEngine(
        EngineConfig(
          modelPath: 'blob:https://example.com/model',
          backend: const Backend.gpu(),
          visionBackend: const Backend.gpu(),
          visualTokenBudget: 70,
        ),
        pageLock: web.LiteRtLmPageLock(),
      );
      expect(
        asMap(list('createSettings').single)['maxVisionTokensPerImage'],
        70,
      );
      await engine.close();
      await expectLater(
        web.createWebEngine(
          EngineConfig(
            modelPath: 'blob:https://example.com/model',
            visualTokenBudget: 70,
          ),
          pageLock: web.LiteRtLmPageLock(),
        ),
        throwsArgumentError,
      );
    },
  );

  test('a per-conversation budget, a chat template and tool call streaming '
      'are refused by name; ToolChoice.auto is taken, another choice and a '
      "message's maxOutputTokens are refused", () async {
    final engine = await webEngine();
    for (final (config, name) in [
      (ConversationConfig(visualTokenBudget: 70), 'visualTokenBudget'),
      (ConversationConfig(chatTemplate: '{{ x }}'), 'chatTemplate'),
      (
        ConversationConfig(enableToolCallStreaming: true),
        'enableToolCallStreaming',
      ),
    ]) {
      await expectLater(
        engine.createConversation(config),
        throwsWith<UnsupportedError>(name),
      );
    }
    final conversation = await engine.createConversation(
      ConversationConfig(tools: [Tool(name: 'weather')]),
    );
    final auto = conversation
        .sendMessageStream(Message.user('hi'), toolChoice: ToolChoice.auto)
        .drain<void>();
    await settle();
    js('__step', 'hello');
    js('__end');
    await auto;
    await expectLater(
      conversation.sendMessageStream(
        Message.user('hi'),
        toolChoice: ToolChoice.required,
      ),
      emitsError(errorWith<UnsupportedError>('other than auto')),
    );
    await expectLater(
      conversation.sendMessageStream(Message.user('hi'), maxOutputTokens: 5),
      emitsError(errorWith<UnsupportedError>('maxOutputTokens')),
    );
    await engine.close();
  });

  test('a conversation counts its tokens and clones on the runtime; '
      'rendering is refused by name', () async {
    final engine = await webEngine();
    final conversation = await engine.createConversation();
    await exchange(conversation, 'My name is Ada.', 'OK.');
    expect(await conversation.getTokenCount(), 7);
    final clone = await conversation.clone();
    expect(count('clones'), 1);
    await exchange(clone, 'Who am I?', 'Ada.');
    // The clone sent on its own runtime conversation.
    expect(list('sent'), hasLength(2));
    expect(
      conversation.renderPrefaceIntoString(),
      throwsWith<UnsupportedError>('no render call'),
    );
    await engine.close();
    expect(count('conversationDeletes'), 2);
  });

  test('a Session prefills text and decodes on the runtime; media and a '
      'streamed decode are refused by name; the engine closes it', () async {
    final engine = await webEngine();
    final session = await engine.createSession();
    await session.runPrefill([const InputData.text('2 + 2?')]);
    expect(await session.runDecode(), 'decoded 1');
    expect(
      await session.generateContent([const InputData.text('3 + 3?')]),
      'decoded 2',
    );
    final clone = await session.clone();
    expect(await clone.runDecode(), 'decoded 2');
    await expectLater(
      session.runPrefill([InputData.image(Uint8List(1))]),
      throwsWith<UnsupportedError>('text only'),
    );
    await expectLater(
      session.generateContentStream([const InputData.text('x')]),
      emitsError(errorWith<UnsupportedError>('no streaming')),
    );
    session.cancelProcess();
    expect(count('sessionCancels'), 1);
    expect(
      engine.createSession(
        SessionConfig(speculativeDecoding: SpeculativeDecodingConfig()),
      ),
      throwsUnsupportedError,
    );
    await engine.close();
    expect(count('sessionDeletes'), 2);
  });
}
