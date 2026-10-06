import 'dart:typed_data';

import 'package:flutter_edge_ai/core/extensions.dart';
import 'package:flutter_edge_ai/core/parsing/sdk_text_extractor.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stream chunks LiteRT-LM 0.17.1 produced for
/// litert-community/Qwen3-4B-Thinking-2507 ("What is 17*23?"): the bundle
/// declares a thought channel, so the runtime streams the reasoning there and
/// the answer as content. Shortened, shapes verbatim.
const _thinkingBundleChunks = [
  '{"role": "assistant", "channels": {"thought": "Okay"}, '
      '"reasoning_content": "Okay"}',
  '{"role": "assistant", "channels": {"thought": ", the"}, '
      '"reasoning_content": ", the"}',
  '{"role": "assistant", "content": [{"type": "text", "text": "39"}]}',
  '{"role": "assistant", "content": [{"type": "text", "text": "1"}]}',
];

Stream<ModelResponse> _sdkStream(List<String> chunks) => Stream.fromIterable(
  chunks.map((c) => TextResponse(SdkTextExtractor.extractTextFromResponse(c))),
);

Stream<ModelResponse> _tokens(List<String> tokens) =>
    Stream.fromIterable(tokens.map(TextResponse.new));

Future<({String thinking, String text})> _split(
  Stream<ModelResponse> source,
  ModelType type,
) async {
  final thinking = StringBuffer();
  final text = StringBuffer();
  await for (final r in ModelThinkingFilter.filterThinkingStream(
    source,
    modelType: type,
  )) {
    if (r is ThinkingResponse) thinking.write(r.content);
    if (r is TextResponse) text.write(r.token);
  }
  return (thinking: thinking.toString(), text: text.toString());
}

/// Records the text of every chunk staged into the session, and streams
/// [tokens] as the model's answer.
class _RecordingSession extends InferenceModelSession {
  _RecordingSession([this.tokens = const []]);

  final List<String> tokens;
  final List<String> staged = [];

  @override
  Future<void> addQueryChunk(Message message) async => staged.add(message.text);

  @override
  Future<String> getResponse() async => '';

  @override
  Stream<String> getResponseAsync() => Stream.fromIterable(tokens);

  @override
  Future<int> sizeInTokens(String text) async => 0;

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {}
}

Future<List<String>> _staged(
  Message message, {
  required ModelType type,
  bool isThinking = false,
}) async {
  final session = _RecordingSession();
  final chat = InferenceChat(
    sessionCreator: () async => session,
    maxTokens: 1024,
    supportAudio: true,
    modelType: type,
    isThinking: isThinking,
    fileType: ModelFileType.litertlm,
  );
  await chat.initSession();
  await chat.addQueryChunk(message);
  return session.staged;
}

void main() {
  group('thought channel, split for every family', () {
    for (final type in [
      ModelType.qwen,
      ModelType.qwen3,
      ModelType.qwen35,
      ModelType.general,
      ModelType.gemma4,
    ]) {
      test('${type.name}: reasoning is thinking, the answer is text', () async {
        final r = await _split(_sdkStream(_thinkingBundleChunks), type);
        expect(r.thinking, 'Okay, the');
        expect(r.text, '391');
      });
    }
  });

  group('<think> tags', () {
    test('qwen35 splits a tag cut across tokens', () async {
      final r = await _split(
        _tokens(['<th', 'ink>r</', 'think>a']),
        ModelType.qwen35,
      );
      expect(r.thinking, 'r');
      expect(r.text, 'a');
    });

    test('a non-thinking Qwen answer stays text', () async {
      final r = await _split(_tokens(['2 + ', '2 = 4.']), ModelType.qwen);
      expect(r.thinking, isEmpty);
      expect(r.text, '2 + 2 = 4.');
    });
  });

  group('removeThinkingFromText', () {
    String strip(String text, ModelType type) =>
        ModelThinkingFilter.removeThinkingFromText(text, modelType: type);

    test('an orphan </think> ends the reasoning (qwen, deepSeek)', () {
      expect(strip('reasoning</think>\n\nanswer', ModelType.qwen), 'answer');
      expect(strip('reasoning</think>answer', ModelType.deepSeek), 'answer');
    });

    test('an empty think block goes (qwen3)', () {
      expect(strip('<think>\n\n</think>\n\nanswer', ModelType.qwen3), 'answer');
    });

    test('a thought-channel block goes for any family', () {
      const text = '<|channel>thought\nreasoning<channel|>answer';
      expect(strip(text, ModelType.general), 'answer');
      expect(strip(text, ModelType.qwen35), 'answer');
    });

    test('text without thinking is returned unchanged (general)', () {
      expect(strip(' answer ', ModelType.general), ' answer ');
    });
  });

  // chat.dart runs the split for every model type, not only the ones that
  // tag their reasoning: a Qwen-based bundle typed `general` streams it on
  // the thought channel too.
  group('InferenceChat, thought channel with thinking off', () {
    for (final type in [ModelType.general, ModelType.qwen3]) {
      test('${type.name}: only the answer reaches the app', () async {
        final session = _RecordingSession(
          _thinkingBundleChunks
              .map(SdkTextExtractor.extractTextFromResponse)
              .toList(),
        );
        final chat = InferenceChat(
          sessionCreator: () async => session,
          maxTokens: 1024,
          modelType: type,
          fileType: ModelFileType.litertlm,
        );
        await chat.initSession();
        await chat.addQueryChunk(const Message(text: 'q', isUser: true));
        final responses = await chat.generateChatResponseAsync().toList();
        expect(responses.whereType<ThinkingResponse>(), isEmpty);
        expect(
          responses.whereType<TextResponse>().map((r) => r.token).join(),
          '391',
        );
      });
    }
  });

  group('/no_think suffix', () {
    const hi = Message(text: 'hi', isUser: true);

    test('qwen3 with thinking off: appended to a text turn', () async {
      expect(await _staged(hi, type: ModelType.qwen3), ['hi /no_think']);
    });

    test('qwen3 with thinking on: not appended', () async {
      expect(await _staged(hi, type: ModelType.qwen3, isThinking: true), [
        'hi',
      ]);
    });

    test('qwen and qwen35: never appended', () async {
      expect(await _staged(hi, type: ModelType.qwen), ['hi']);
      expect(await _staged(hi, type: ModelType.qwen35), ['hi']);
    });

    // Qwen3-ASR's bundle prints the user's text as the start of its answer:
    // with " /no_think" there it returns an empty transcript.
    test('qwen3: not appended to an audio turn', () async {
      final audio = Message.audioOnly(audioBytes: Uint8List(4), isUser: true);
      expect(await _staged(audio, type: ModelType.qwen3), ['']);
    });

    test('qwen3: not appended to a tool response', () async {
      final response = Message.toolResponse(
        toolName: 'get_time',
        response: const {'time': '12:00'},
      );
      final staged = await _staged(response, type: ModelType.qwen3);
      expect(staged.single, isNot(contains('/no_think')));
    });
  });
}
