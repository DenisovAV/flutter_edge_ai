import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart'
    show
        InferenceChat,
        Message,
        ModelResponse,
        SpeechRecognizer,
        SpeechSynthesizer,
        TextResponse,
        ThinkingResponse,
        FunctionCallResponse,
        Tool;
import 'package:flutter_gemma_speech/src/voice/voice_event.dart'
    show VoiceReplyTextEvent;
import 'package:flutter_gemma_speech/src/voice/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopRecognizer implements SpeechRecognizer {
  @override
  String? language;

  @override
  Future<String> transcribe(Uint8List pcm, {String? language}) async => '';
  @override
  void addCloseListener(void Function() l) {}
  @override
  Future<void> close() async {}
}

/// Fixed transcript so a turn actually runs.
class _FixedRecognizer implements SpeechRecognizer {
  @override
  String? language;

  @override
  Future<String> transcribe(Uint8List pcm, {String? language}) async => 'hi';
  @override
  void addCloseListener(void Function() l) {}
  @override
  Future<void> close() async {}
}

/// Scripts one `generateChatResponseAsync` turn per entry (falls back to a
/// 'done' text turn), so the real `generateChatResponseWithTools` loop can be
/// driven through `VoiceSession.fromChat` without a native session.
class _ScriptChat extends InferenceChat {
  _ScriptChat(this._turns)
    : super(
        sessionCreator: null,
        maxTokens: 1024,
        tools: const [Tool(name: 'get_time', description: 't')],
      );
  final List<List<ModelResponse>> _turns;
  int _i = 0;
  int generations = 0;

  @override
  Future<void> addQueryChunk(
    Message m, [
    bool noTool = false,
    bool prefix = false,
  ]) async {}

  @override
  Stream<ModelResponse> generateChatResponseAsync() async* {
    generations++;
    final turn = _i < _turns.length
        ? _turns[_i++]
        : const <ModelResponse>[TextResponse('done')];
    for (final r in turn) {
      yield r;
    }
  }

  @override
  Future<void> stopGeneration() async {}
  @override
  Future<void> close() async {}
}

class _NoopSynth implements SpeechSynthesizer {
  @override
  int get sampleRate => 22050;
  @override
  Future<Uint8List> synthesize(String t) async => Uint8List(0);
  @override
  void addCloseListener(void Function() l) {}
  @override
  Future<void> close() async {}
}

void main() {
  test('fromChat with a tools-chat but no onToolCall throws', () {
    final chatWithTools = InferenceChat(
      sessionCreator: null,
      maxTokens: 1024,
      tools: const [Tool(name: 'noop', description: 'noop')],
    );
    expect(
      () => VoiceSession.fromChat(
        recognizer: _NoopRecognizer(),
        chat: chatWithTools,
        synthesizer: _NoopSynth(),
      ),
      throwsArgumentError,
    );
  });

  test('fromChat with a tools-chat AND onToolCall builds a session', () {
    final chatWithTools = InferenceChat(
      sessionCreator: null,
      maxTokens: 1024,
      tools: const [Tool(name: 'noop', description: 'noop')],
    );
    final session = VoiceSession.fromChat(
      recognizer: _NoopRecognizer(),
      chat: chatWithTools,
      synthesizer: _NoopSynth(),
      onToolCall: (c) async => {'result': 'ok'},
    );
    expect(session, isA<VoiceSession>());
  });

  test('fromChat builds a session when the chat is tools-free', () {
    final chat = InferenceChat(sessionCreator: null, maxTokens: 1024);
    final session = VoiceSession.fromChat(
      recognizer: _NoopRecognizer(),
      chat: chat,
      synthesizer: _NoopSynth(),
    );
    expect(session, isA<VoiceSession>());
    expect(session.replySampleRate, 22050);
  });

  test(
    'fromChat tools path: runTurn invokes onToolCall and surfaces the reply',
    () async {
      final chat = _ScriptChat([
        const [FunctionCallResponse(name: 'get_time', args: {})],
        const [TextResponse('done')],
      ]);
      var called = false;
      final session = VoiceSession.fromChat(
        recognizer: _FixedRecognizer(),
        chat: chat,
        synthesizer: _NoopSynth(),
        onToolCall: (c) {
          called = true;
          return {'result': 'x'};
        },
      );

      final events = await session.runTurn(Uint8List(0)).toList();

      expect(
        called,
        isTrue,
        reason: 'onToolCall must fire on the function call',
      );
      final reply = events
          .whereType<VoiceReplyTextEvent>()
          .map((e) => e.chunk)
          .join();
      expect(
        reply,
        'done',
        reason: 'the post-tool answer must surface as reply text',
      );
      expect(
        chat.generations,
        2,
        reason: 'one generation for the call, one for the answer',
      );
    },
  );

  test(
    'fromChat tools path: interrupt() halts the loop before the next generation',
    () async {
      final chat = _ScriptChat([
        const [FunctionCallResponse(name: 'get_time', args: {})],
        const [TextResponse('unreachable')], // 2nd generation must NOT run
      ]);
      final toolFired = Completer<void>();
      final letToolReturn = Completer<void>();
      final session = VoiceSession.fromChat(
        recognizer: _FixedRecognizer(),
        chat: chat,
        synthesizer: _NoopSynth(),
        onToolCall: (c) async {
          if (!toolFired.isCompleted) toolFired.complete();
          await letToolReturn.future; // hang the tool mid-turn
          return {'result': 'x'};
        },
      );

      final events = session.runTurn(Uint8List(0)).toList();
      await toolFired.future; // the tool is now running (turn in flight)
      final interrupting = session.interrupt(); // cancels this turn's token
      letToolReturn.complete(); // tool returns; loop then sees the cancel
      await interrupting;
      await events;

      expect(
        chat.generations,
        1,
        reason:
            'barge-in must stop the tool loop before the 2nd generation; '
            'the per-turn cancel token propagates to generateChatResponseWithTools',
      );
    },
  );

  test('textTokensOf keeps only TextResponse tokens, in order', () async {
    Stream<ModelResponse> responses() async* {
      yield const ThinkingResponse('...thinking...');
      yield const TextResponse('Hello');
      yield const FunctionCallResponse(name: 'x', args: {});
      yield const TextResponse(' world');
    }

    final tokens = await VoiceSession.textTokensOf(responses()).toList();
    expect(tokens, ['Hello', ' world']);
  });
}
