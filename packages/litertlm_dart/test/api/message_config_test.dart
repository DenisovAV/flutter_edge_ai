// The API's value types: messages and their Conversation API JSON, tools,
// and the configs' checks and defaults.
import 'dart:convert';
import 'dart:typed_data';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

void main() {
  group('Message', () {
    test('a user message is serialized in its parts order, media as blobs', () {
      final image = Uint8List.fromList([1, 2]);
      final audio = Uint8List.fromList([3]);
      final json = messageJson(
        Message(
          role: Role.user,
          contents: [
            Content.audioBytes(audio),
            Content.text('what'),
            Content.imageBytes(image),
            const Content.imageFile('/p.png'),
          ],
        ),
      );
      expect(json, {
        'role': 'user',
        'content': [
          {'type': 'audio', 'blob': base64Encode(audio)},
          {'type': 'text', 'text': 'what'},
          {'type': 'image', 'blob': base64Encode(image)},
          {'type': 'image', 'path': '/p.png'},
        ],
      });
    });

    test('a tool message carries its responses; a model reply its calls', () {
      expect(
        messageJson(
          Message.tool([
            const Content.toolResponse('get_weather', {'temp': 21}),
          ]),
        ),
        {
          'role': 'tool',
          'content': [
            {
              'type': 'tool_response',
              'name': 'get_weather',
              'response': {'temp': 21},
            },
          ],
        },
      );
      expect(
        messageJson(
          Message(
            role: Role.model,
            toolCalls: [
              ToolCall('get_weather', {'city': 'Oslo'}),
            ],
          ),
        ),
        {
          'role': 'assistant',
          'tool_calls': [
            {
              'type': 'function',
              'function': {
                'name': 'get_weather',
                'arguments': {'city': 'Oslo'},
              },
            },
          ],
        },
      );
    });

    test('a streamed chunk: text, a thought, calls, and plain text', () {
      final text = messageFromChunk(
        '{"role":"assistant","content":[{"type":"text","text":"Hi"}]}',
      );
      expect(text.role, Role.model);
      expect(text.text, 'Hi');

      final thought = messageFromChunk(
        '{"role":"assistant","channels":{"thought":"hmm"}}',
      );
      expect(thought.channels, {'thought': 'hmm'});
      expect(thought.contents, isEmpty);

      final call = messageFromChunk(
        '{"role":"assistant","tool_calls":[{"type":"function","function":'
        '{"name":"f","arguments":{"a":1}}}]}',
      );
      expect(call.toolCalls.single.name, 'f');
      expect(call.toolCalls.single.arguments, {'a': 1});

      // Arguments sent as a JSON string are read as the object they hold.
      final stringArgs = messageFromChunk(
        '{"role":"assistant","tool_calls":[{"function":'
        '{"name":"f","arguments":"{\\"a\\":2}"}}]}',
      );
      expect(stringArgs.toolCalls.single.arguments, {'a': 2});

      expect(messageFromChunk('plain words').text, 'plain words');
      expect(messageFromChunk('{"role":"assistant","content":"s"}').text, 's');
    });

    test('the calls a replay keeps: a reply it cannot read has none, and '
        'does not throw', () {
      expect(
        nativeToolCalls(
          '{"role":"assistant","tool_calls":[{"function":{"name":"f",'
          '"arguments":"not json"}}]}'
          '{"role":"assistant","content":5}'
          '{"role":"assistant","tool_calls":[{"function":{"name":"g",'
          '"arguments":{}}}]}',
        ).map((c) => c.name),
        ['g'],
      );
    });

    test('content of another type is a contract change, not text', () {
      expect(
        () => messageFromChunk('{"role":"assistant","content":7}'),
        throwsStateError,
      );
    });

    test('collections are copied: a caller cannot change a message', () {
      final contents = <Content>[Content.text('a')];
      final bytes = Uint8List.fromList([1]);
      final message = Message(
        role: Role.user,
        contents: contents..add(Content.imageBytes(bytes)),
      );
      contents.clear();
      bytes[0] = 9;
      expect(message.contents, hasLength(2));
      expect((message.contents[1] as ImageBytesContent).bytes, [1]);
      expect(() => message.contents.add(Content.text('b')), throwsA(anything));
    });

    test('tools as tools_json; none is null', () {
      expect(toolsJson(const []), isNull);
      expect(
        jsonDecode(
          toolsJson([
            Tool(
              name: 'f',
              description: 'does f',
              parameters: const {'type': 'object'},
            ),
          ])!,
        ),
        [
          {
            'type': 'function',
            'function': {
              'name': 'f',
              'description': 'does f',
              'parameters': {'type': 'object'},
            },
          },
        ],
      );
      expect(() => Tool(name: ''), throwsArgumentError);
    });
  });

  group('configs', () {
    test('SamplerConfig refuses values no engine samples with', () {
      expect(
        () => SamplerConfig(topK: 0, topP: 0.9, temperature: 1),
        throwsArgumentError,
      );
      expect(
        () => SamplerConfig(topK: 1, topP: 0, temperature: 1),
        throwsArgumentError,
      );
      expect(
        () => SamplerConfig(topK: 1, topP: 1.1, temperature: 1),
        throwsArgumentError,
      );
      expect(
        () => SamplerConfig(topK: 1, topP: 1, temperature: -0.1),
        throwsArgumentError,
      );
      expect(
        () => SamplerConfig(topK: 1, topP: 1, temperature: double.infinity),
        throwsArgumentError,
      );
      expect(SamplerConfig(topK: 1, topP: 1, temperature: 0).seed, 0);
    });

    test('ThinkingConfig takes a budget of 1..0x7fffffff', () {
      expect(() => ThinkingConfig(thinkingTokenBudget: 0), throwsArgumentError);
      expect(
        () => ThinkingConfig(thinkingTokenBudget: maxThinkingTokenBudget + 1),
        throwsArgumentError,
      );
      expect(
        ThinkingConfig(
          thinkingTokenBudget: maxThinkingTokenBudget,
        ).thinkingTokenBudget,
        maxThinkingTokenBudget,
      );
    });

    test('the penalty configs check what Kotlin checks', () {
      expect(
        () => RepetitionPenaltyConfig(repetitionPenalty: 0.9),
        throwsArgumentError,
      );
      expect(
        () => RepetitionPenaltyConfig(windowSize: -1),
        throwsArgumentError,
      );
      expect(
        () => NoRepeatNgramConfig(noRepeatNgramSize: -1),
        throwsArgumentError,
      );
      expect(() => NoRepeatNgramConfig(windowSize: -1), throwsArgumentError);
      expect(
        RepetitionPenaltyConfig(repetitionPenalty: 1.2).windowSize,
        isNull,
      );
    });

    test(
      'ResponseFormat: a schema is encoded once; an empty regex refused',
      () {
        final format = ResponseFormat.json(const {'type': 'string'});
        expect(format, isA<JsonResponseFormat>());
        expect((format as JsonResponseFormat).schemaJson, '{"type":"string"}');
        expect(() => ResponseFormat.regex(''), throwsArgumentError);
        expect(
          (ResponseFormat.regex('[a-z]+') as RegexResponseFormat).pattern,
          '[a-z]+',
        );
      },
    );

    test('a conversation needs a positive output cap', () {
      expect(() => ConversationConfig(maxOutputTokens: 0), throwsArgumentError);
    });

    test(
      "an unset sampler is the file's, field by field, then 0.8/40/0.95/1",
      () {
        expect(
          samplerFor(null, const BundleSampler(topK: 20, temperature: 0.6)),
          const Sampler(temperature: 0.6, topK: 20, topP: 0.95, randomSeed: 1),
        );
        expect(
          samplerFor(null, const BundleSampler()),
          const Sampler(temperature: 0.8, topK: 40, topP: 0.95, randomSeed: 1),
        );
        expect(
          samplerFor(
            SamplerConfig(topK: 1, topP: 1, temperature: 0, seed: 7),
            const BundleSampler(topK: 20),
          ),
          const Sampler(temperature: 0, topK: 1, topP: 1, randomSeed: 7),
        );
      },
    );

    test('an engine config without a backend runs on the CPU', () {
      expect(EngineConfig(modelPath: 'm').backend, const Backend.cpu());
      expect(const Backend.cpu(threadCount: 4), isNot(const Backend.cpu()));
      expect(backendKindOf(Backend.npu(dispatchDir: '/d')), BackendKind.npu);
    });
  });
}
