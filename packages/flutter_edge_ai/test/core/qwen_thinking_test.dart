import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/src/extensions.dart';
import 'package:flutter_edge_ai/src/parsing/sdk_text_extractor.dart';
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

/// One session of a chat: records each staged text into [wire] (shared by
/// every session the chat opens) and answers the next turn with the next of
/// [replies]; a reply's token count is its entry in [replyTokens].
class _WireSession extends InferenceModelSession {
  _WireSession(this.wire, this.replies, this.replyTokens);

  final List<List<String>> wire;
  final List<String> replies;
  final Map<String, int> replyTokens;
  late final List<String> staged = () {
    final list = <String>[];
    wire.add(list);
    return list;
  }();

  @override
  Future<void> addQueryChunk(Message message) async => staged.add(message.text);

  @override
  Future<String> getResponse() async => replies.removeAt(0);

  @override
  Stream<String> getResponseAsync() => Stream.value(replies.removeAt(0));

  @override
  Future<int> sizeInTokens(String text) async => replyTokens[text] ?? 0;

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {}
}

/// A chat whose sessions record what each one was sent: `wire[i]` is the
/// i-th session's input, in order.
Future<({InferenceChat chat, List<List<String>> wire})> _wireChat({
  required ModelType type,
  bool isThinking = false,
  required List<String> replies,
  Map<String, int> replyTokens = const {},
  int maxTokens = 1024,
  int tokenBuffer = 0,
}) async {
  final wire = <List<String>>[];
  final chat = InferenceChat(
    sessionCreator: () async {
      final session = _WireSession(wire, replies, replyTokens);
      session.staged; // registers the session's list in [wire]
      return session;
    },
    maxTokens: maxTokens,
    tokenBuffer: tokenBuffer,
    modelType: type,
    enableThinking: isThinking,
    fileType: ModelFileType.litertlm,
  );
  await chat.initSession();
  return (chat: chat, wire: wire);
}

Future<void> _turn(
  InferenceChat chat,
  String text, {
  bool streaming = false,
}) async {
  await chat.addQueryChunk(Message(text: text, isUser: true));
  if (streaming) {
    // Only the streaming path counts reply tokens and rebuilds the session.
    await chat.generateChatResponseAsync().drain<void>();
  } else {
    await chat.generateChatResponse();
  }
}

int _suffixes(String text) => '/no_think'.allMatches(text).length;

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
    enableThinking: isThinking,
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
      // DeepSeek's own filter starts inside the reasoning; reasoning that
      // came on the channel must not keep it there for the answer.
      ModelType.deepSeek,
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

    // DeepSeek starts inside its reasoning, so its first </think> ends it;
    // a later </think> is the answer talking about the tag.
    test('deepSeek: the first orphan </think> ends the reasoning', () {
      expect(strip('reasoning</think>answer', ModelType.deepSeek), 'answer');
      expect(
        strip('r</think>The tag </think> closes it.', ModelType.deepSeek),
        'The tag </think> closes it.',
      );
    });

    // A Qwen answer starts outside any reasoning: a </think> in it is text.
    test('qwen: a </think> in the answer is kept', () {
      const answer = 'Use text.split("</think>")[-1] to drop it.';
      expect(strip(answer, ModelType.qwen), answer);
      expect(strip(answer, ModelType.qwen3), answer);
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
    for (final type in [
      ModelType.general,
      ModelType.qwen3,
      ModelType.deepSeek,
    ]) {
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

  group('hidden reasoning notice', () {
    Future<List<String>> printedOverTwoTurns(List<String> tokens) async {
      final printed = <String>[];
      await runZoned(
        () async {
          final chat = InferenceChat(
            sessionCreator: () async => _RecordingSession(tokens),
            maxTokens: 1024,
            modelType: ModelType.general,
            fileType: ModelFileType.litertlm,
          );
          await chat.initSession();
          for (var turn = 0; turn < 2; turn++) {
            await chat.addQueryChunk(const Message(text: 'q', isUser: true));
            await chat.generateChatResponseAsync().toList();
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      return printed
          .where((l) => l.contains('reasoned although thinking is off'))
          .toList();
    }

    test(
      'reasoning hidden with thinking off is reported once per chat',
      () async {
        final chunks = _thinkingBundleChunks
            .map(SdkTextExtractor.extractTextFromResponse)
            .toList();
        expect(await printedOverTwoTurns(chunks), hasLength(1));
      },
    );

    test('an answer without reasoning is not reported', () async {
      expect(await printedOverTwoTurns(['2 + 2 = 4.']), isEmpty);
    });
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

    group('stays out of the histories the app sees', () {
      test('qwen3 with thinking off: fullHistory keeps the caller\'s text, '
          'the model gets the suffix', () async {
        final (:chat, :wire) = await _wireChat(
          type: ModelType.qwen3,
          replies: ['hello'],
        );
        await _turn(chat, 'hi');
        expect(wire.single, ['hi /no_think']);
        expect(chat.fullHistory.map((m) => m.text), ['hi', 'hello']);
      });

      test('qwen3: replaying fullHistory sends one suffix per user turn and '
          'fullHistory keeps none', () async {
        final (:chat, :wire) = await _wireChat(
          type: ModelType.qwen3,
          replies: ['a1', 'a2', 'a3'],
        );
        await _turn(chat, 'q1');
        await _turn(chat, 'q2');
        final saved = chat.fullHistory;

        await chat.clearHistory(replayHistory: saved);
        await _turn(chat, 'q3');
        // And once more, from a history that was itself replayed.
        await chat.clearHistory(replayHistory: chat.fullHistory);

        final replayed = wire[1];
        expect(replayed, [
          'q1 /no_think',
          'a1',
          'q2 /no_think',
          'a2',
          'q3 '
              '/no_think',
        ]);
        expect(wire[2], [...replayed, 'a3']);
        for (final text in wire.expand((s) => s)) {
          expect(_suffixes(text), text.startsWith('q') ? 1 : 0, reason: text);
        }
        expect(chat.fullHistory.map((m) => m.text), [
          'q1',
          'a1',
          'q2',
          'a2',
          'q3',
          'a3',
        ]);
      });

      test(
        'qwen3: a history saved with the suffix is not sent with two',
        () async {
          final (:chat, :wire) = await _wireChat(
            type: ModelType.qwen3,
            replies: [],
          );
          await chat.clearHistory(
            replayHistory: const [Message(text: 'q1 /no_think', isUser: true)],
          );
          expect(wire.last, ['q1 /no_think']);
        },
      );

      test('qwen3: a session rebuilt for the context window keeps the '
          'suffix the model got', () async {
        // maxTokens - tokenBuffer = 40: the second reply takes the count to
        // 60, the rebuild drops q1 and a1 (30) and replays q2 and a2.
        final (:chat, :wire) = await _wireChat(
          type: ModelType.qwen3,
          replies: ['a1', 'a2'],
          replyTokens: {'a1': 30, 'a2': 30},
          maxTokens: 60,
          tokenBuffer: 20,
        );
        await _turn(chat, 'q1', streaming: true);
        await _turn(chat, 'q2', streaming: true);
        expect(wire, hasLength(2));
        expect(wire.last, ['q2 /no_think', 'a2']);
        expect(chat.fullHistory.map((m) => m.text), ['q1', 'a1', 'q2', 'a2']);
      });

      for (final (type, isThinking) in [
        (ModelType.qwen3, true),
        (ModelType.qwen, false),
        (ModelType.qwen35, false),
        (ModelType.gemmaIt, false),
      ]) {
        test('${type.name}, thinking ${isThinking ? 'on' : 'off'}: nothing '
            'appended anywhere', () async {
          final (:chat, :wire) = await _wireChat(
            type: type,
            isThinking: isThinking,
            replies: ['a1', 'a2'],
          );
          await _turn(chat, 'q1');
          await chat.clearHistory(replayHistory: chat.fullHistory);
          await _turn(chat, 'q2');
          expect(wire, [
            ['q1'],
            ['q1', 'a1', 'q2'],
          ]);
          expect(chat.fullHistory.map((m) => m.text), ['q1', 'a1', 'q2', 'a2']);
        });
      }
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
