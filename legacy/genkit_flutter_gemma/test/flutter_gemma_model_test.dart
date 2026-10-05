import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_gemma/src/flutter_gemma_model.dart';
import 'package:genkit_flutter_gemma/src/flutter_gemma_options.dart';

import 'src/fake_runtime.dart';

void main() {
  late FakeRuntime runtime;
  late FakeInferenceChat fakeChat;
  late FakeInferenceModel fakeModel;

  setUp(() {
    fakeChat = FakeInferenceChat();
    fakeModel = FakeInferenceModel()..chatToReturn = fakeChat;
    runtime = FakeRuntime(model: fakeModel);
  });

  Model buildModel() {
    return createFlutterGemmaModel(
      name: 'flutter-gemma/test-model',
      modelType: gemma.ModelType.gemmaIt,
      fileType: gemma.ModelFileType.task,
      runtime: runtime,
    );
  }

  ModelRequest simpleRequest([String text = 'Hello']) {
    return ModelRequest(
      messages: [
        Message(
          role: Role.user,
          content: [TextPart(text: text)],
        ),
      ],
    );
  }

  group('createFlutterGemmaModel', () {
    test('blocking: returns text response', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('Hello back!');

      final model = buildModel();
      final response = await model(simpleRequest());

      expect(response.message!.content.first.isText, isTrue);
      expect(response.message!.content.first.text, 'Hello back!');
      expect(response.finishReason, FinishReason.stop);
    });

    test('blocking: returns function call response', () async {
      fakeChat.blockingResponse = const gemma.FunctionCallResponse(
        name: 'get_weather',
        args: {'city': 'Moscow'},
      );

      final model = buildModel();
      final response = await model(simpleRequest());

      expect(response.message!.content.first.isToolRequest, isTrue);
      final toolReq = response.message!.content.first.toolRequest!;
      expect(toolReq.name, 'get_weather');
      expect(toolReq.input, {'city': 'Moscow'});
    });

    test('streaming: sends chunks and returns final response', () async {
      fakeChat.streamingResponses = [
        const gemma.TextResponse('Hello '),
        const gemma.TextResponse('world!'),
      ];

      final model = buildModel();
      final chunks = <ModelResponseChunk>[];

      final response = await model(simpleRequest(), onChunk: chunks.add);

      expect(chunks, hasLength(2));
      expect(chunks[0].content.first.isText, isTrue);
      expect(chunks[0].content.first.text, 'Hello ');
      expect(chunks[1].content.first.text, 'world!');
      expect(response.message!.content.first.text, 'Hello world!');
    });

    test('streaming: handles function call in stream', () async {
      fakeChat.streamingResponses = [
        const gemma.FunctionCallResponse(name: 'search', args: {'q': 'dart'}),
      ];

      final model = buildModel();
      final chunks = <ModelResponseChunk>[];

      final response = await model(simpleRequest(), onChunk: chunks.add);

      expect(response.message!.content.first.isToolRequest, isTrue);
      expect(response.message!.content.first.toolRequest!.name, 'search');
    });

    test('caches model when config is unchanged', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(simpleRequest('first'));
      await model(simpleRequest('second'));

      expect(runtime.getActiveModelCallCount, 1);
      expect(fakeModel.createChatCallCount, 2);
    });

    test('recreates model when config changes', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      // First call with default config.
      await model(simpleRequest());

      // Second call with different maxTokens.
      final request = ModelRequest(
        messages: [
          Message(
            role: Role.user,
            content: [TextPart(text: 'Hi')],
          ),
        ],
        config: {'maxTokens': 2048},
      );
      await model(request);

      expect(runtime.getActiveModelCallCount, 2);
    });

    test('converts messages and passes to chat', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');

      final model = buildModel();
      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hello')],
            ),
            Message(
              role: Role.model,
              content: [TextPart(text: 'Hi')],
            ),
            Message(
              role: Role.user,
              content: [TextPart(text: 'How are you?')],
            ),
          ],
        ),
      );

      expect(fakeChat.addQueryChunkCallCount, 3);
      expect(fakeChat.receivedMessages[0].text, 'Hello');
      expect(fakeChat.receivedMessages[0].isUser, isTrue);
      expect(fakeChat.receivedMessages[1].text, 'Hi');
      expect(fakeChat.receivedMessages[1].isUser, isFalse);
      expect(fakeChat.receivedMessages[2].text, 'How are you?');
    });

    test('passes toolChoice required to createChat', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'toolChoice': 'required'},
        ),
      );

      expect(fakeModel.lastToolChoice, gemma.ToolChoice.required);
    });

    test('passes toolChoice none to createChat', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'toolChoice': 'none'},
        ),
      );

      expect(fakeModel.lastToolChoice, gemma.ToolChoice.none);
    });

    test('native request.toolChoice reaches createChat (0.15)', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          toolChoice: 'required', // top-level native field, not config
        ),
      );

      expect(fakeModel.lastToolChoice, gemma.ToolChoice.required);
    });

    test('native request.toolChoice wins over config.toolChoice', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          toolChoice: 'none',
          config: {'toolChoice': 'required'},
        ),
      );

      expect(fakeModel.lastToolChoice, gemma.ToolChoice.none);
    });

    test(
      'advertises supports (toolChoice, constrained, json) in Model metadata',
      () {
        final supports =
            (buildModel().metadata['model'] as Map)['supports'] as Map;
        expect(supports['multiturn'], isTrue);
        expect(supports['media'], isTrue);
        expect(supports['tools'], isTrue);
        expect(supports['systemRole'], isTrue);
        expect(supports['toolChoice'], isTrue);
        expect(supports['constrained'], isFalse);
        expect(supports['output'], containsAll(<String>['text', 'json']));
      },
    );

    test('defaults toolChoice to auto', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(simpleRequest());

      expect(fakeModel.lastToolChoice, gemma.ToolChoice.auto);
    });

    test('passes maxFunctionBufferLength to createChat when set', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'maxFunctionBufferLength': 4096},
        ),
      );

      expect(fakeModel.lastMaxFunctionBufferLength, 4096);
    });

    test(
      'passes null maxFunctionBufferLength to createChat when not set',
      () async {
        fakeChat.blockingResponse = const gemma.TextResponse('ok');
        final model = buildModel();

        await model(simpleRequest());

        expect(fakeModel.lastMaxFunctionBufferLength, isNull);
      },
    );

    test(
      'passes enableSpeculativeDecoding to getActiveModel when set',
      () async {
        fakeChat.blockingResponse = const gemma.TextResponse('ok');
        final model = buildModel();

        await model(
          ModelRequest(
            messages: [
              Message(
                role: Role.user,
                content: [TextPart(text: 'Hi')],
              ),
            ],
            config: {'enableSpeculativeDecoding': true},
          ),
        );

        expect(runtime.lastEnableSpeculativeDecoding, isTrue);
      },
    );

    test('passes null enableSpeculativeDecoding when not set', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(simpleRequest());

      expect(runtime.lastEnableSpeculativeDecoding, isNull);
    });

    test('recreates model when enableSpeculativeDecoding changes', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(simpleRequest());
      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'enableSpeculativeDecoding': false},
        ),
      );

      expect(runtime.getActiveModelCallCount, 2);
    });

    test(
      'recreates model when enableSpeculativeDecoding reverts to null',
      () async {
        fakeChat.blockingResponse = const gemma.TextResponse('ok');
        final model = buildModel();

        await model(
          ModelRequest(
            messages: [
              Message(
                role: Role.user,
                content: [TextPart(text: 'Hi')],
              ),
            ],
            config: {'enableSpeculativeDecoding': true},
          ),
        );
        await model(simpleRequest());

        expect(runtime.getActiveModelCallCount, 2);
        expect(runtime.lastEnableSpeculativeDecoding, isNull);
      },
    );

    test('passes preferredBackend to getActiveModel when set', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'preferredBackend': 'gpu'},
        ),
      );

      expect(runtime.lastPreferredBackend, gemma.PreferredBackend.gpu);
    });

    test('passes preferredVisionBackend to getActiveModel when set', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'preferredVisionBackend': 'gpu'},
        ),
      );

      expect(runtime.lastPreferredVisionBackend, gemma.PreferredBackend.gpu);
    });

    test('passes preferredAudioBackend to getActiveModel when set', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'preferredAudioBackend': 'gpu'},
        ),
      );

      expect(runtime.lastPreferredAudioBackend, gemma.PreferredBackend.gpu);
    });

    test('passes null backends to getActiveModel when not set', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(simpleRequest());

      expect(runtime.lastPreferredBackend, isNull);
      expect(runtime.lastPreferredVisionBackend, isNull);
      expect(runtime.lastPreferredAudioBackend, isNull);
    });

    test('invalid preferredVisionBackend throws GenkitException', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await expectLater(
        model(
          ModelRequest(
            messages: [
              Message(
                role: Role.user,
                content: [TextPart(text: 'Hi')],
              ),
            ],
            config: {'preferredVisionBackend': 'xyz'},
          ),
        ),
        throwsA(
          isA<GenkitException>().having(
            (e) => e.status,
            'status',
            StatusCodes.INVALID_ARGUMENT,
          ),
        ),
      );
    });

    test('recreates model when preferredVisionBackend changes', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(simpleRequest());
      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'preferredVisionBackend': 'gpu'},
        ),
      );

      expect(runtime.getActiveModelCallCount, 2);
      // Recreated AND forwarded the new value (not a stale-value recreate).
      expect(runtime.lastPreferredVisionBackend, gemma.PreferredBackend.gpu);
    });

    test('recreates model when preferredBackend changes', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(simpleRequest());
      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'preferredBackend': 'gpu'},
        ),
      );

      expect(runtime.getActiveModelCallCount, 2);
      expect(runtime.lastPreferredBackend, gemma.PreferredBackend.gpu);
    });

    test('recreates model when preferredAudioBackend changes', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(simpleRequest());
      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'preferredAudioBackend': 'gpu'},
        ),
      );

      expect(runtime.getActiveModelCallCount, 2);
      expect(runtime.lastPreferredAudioBackend, gemma.PreferredBackend.gpu);
    });

    test('FlutterGemmaModelOptions round-trips backend strings', () {
      final json = FlutterGemmaModelOptions(
        preferredBackend: 'npu',
        preferredVisionBackend: 'gpu',
        preferredAudioBackend: 'cpu',
      ).toJson();

      expect(json['preferredBackend'], 'npu');
      expect(json['preferredVisionBackend'], 'gpu');
      expect(json['preferredAudioBackend'], 'cpu');

      final parsed = FlutterGemmaModelOptions.fromJson(json);
      expect(parsed.preferredBackend, 'npu');
      expect(parsed.preferredVisionBackend, 'gpu');
      expect(parsed.preferredAudioBackend, 'cpu');
    });

    test('blocking: returns parallel function call response', () async {
      fakeChat.blockingResponse = const gemma.ParallelFunctionCallResponse(
        calls: [
          gemma.FunctionCallResponse(
            name: 'get_weather',
            args: {'city': 'Moscow'},
          ),
          gemma.FunctionCallResponse(name: 'get_time', args: {'tz': 'MSK'}),
        ],
      );

      final model = buildModel();
      final response = await model(simpleRequest());

      final parts = response.message!.content;
      expect(parts, hasLength(2));
      expect(parts[0].isToolRequest, isTrue);
      expect(parts[0].toolRequest!.name, 'get_weather');
      expect(parts[1].isToolRequest, isTrue);
      expect(parts[1].toolRequest!.name, 'get_time');
    });

    test('streaming: accumulates parallel function calls', () async {
      fakeChat.streamingResponses = [
        const gemma.TextResponse('thinking... '),
        const gemma.ParallelFunctionCallResponse(
          calls: [
            gemma.FunctionCallResponse(name: 'a', args: {'x': 1}),
            gemma.FunctionCallResponse(name: 'b', args: {'y': 2}),
          ],
        ),
      ];

      final model = buildModel();
      final chunks = <ModelResponseChunk>[];

      final response = await model(simpleRequest(), onChunk: chunks.add);

      expect(chunks, hasLength(2));
      final parts = response.message!.content;
      expect(parts.where((p) => p.isToolRequest).length, 2);
    });

    test('blocking: returns reasoning for ThinkingResponse', () async {
      fakeChat.blockingResponse = const gemma.ThinkingResponse('step by step');

      final model = buildModel();
      final response = await model(simpleRequest());

      final parts = response.message!.content;
      expect(parts, hasLength(1));
      expect(parts.first.isReasoning, isTrue);
      expect(parts.first.reasoning, 'step by step');
    });

    test('streaming: accumulates thinking chunks', () async {
      fakeChat.streamingResponses = [
        const gemma.ThinkingResponse('step 1. '),
        const gemma.ThinkingResponse('step 2. '),
        const gemma.TextResponse('answer'),
      ];

      final model = buildModel();
      final chunks = <ModelResponseChunk>[];

      final response = await model(simpleRequest(), onChunk: chunks.add);

      expect(chunks, hasLength(3));
      expect(chunks[0].content.first.isReasoning, isTrue);
      expect(chunks[2].content.first.isText, isTrue);

      final parts = response.message!.content;
      expect(parts, hasLength(2));
      expect(parts[0].isReasoning, isTrue);
      expect(parts[0].reasoning, 'step 1. step 2. ');
      expect(parts[1].isText, isTrue);
      expect(parts[1].text, 'answer');
    });

    test('blocking: response includes latencyMs', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      final response = await model(simpleRequest());

      expect(response.latencyMs, isNotNull);
      expect(response.latencyMs, greaterThanOrEqualTo(0));
    });

    test('streaming: response includes latencyMs', () async {
      fakeChat.streamingResponses = [const gemma.TextResponse('ok')];
      final model = buildModel();

      final response = await model(simpleRequest(), onChunk: (_) {});

      expect(response.latencyMs, isNotNull);
      expect(response.latencyMs, greaterThanOrEqualTo(0));
    });

    test('null request throws GenkitException', () async {
      final model = buildModel();

      await expectLater(model(null), throwsA(isA<GenkitException>()));
    });

    test('passes systemInstruction from config to createChat', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
          config: {'systemInstruction': 'Be concise.'},
        ),
      );

      expect(fakeModel.lastSystemInstruction, 'Be concise.');
    });

    test('extracts systemInstruction from system messages', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.system,
              content: [TextPart(text: 'You are helpful.')],
            ),
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hi')],
            ),
          ],
        ),
      );

      expect(fakeModel.lastSystemInstruction, 'You are helpful.');
    });

    test(
      'config systemInstruction takes priority over system messages',
      () async {
        fakeChat.blockingResponse = const gemma.TextResponse('ok');
        final model = buildModel();

        await model(
          ModelRequest(
            messages: [
              Message(
                role: Role.system,
                content: [TextPart(text: 'From message.')],
              ),
              Message(
                role: Role.user,
                content: [TextPart(text: 'Hi')],
              ),
            ],
            config: {'systemInstruction': 'From config.'},
          ),
        );

        expect(fakeModel.lastSystemInstruction, 'From config.');
      },
    );

    test('system messages are not prepended to user messages', () async {
      fakeChat.blockingResponse = const gemma.TextResponse('ok');
      final model = buildModel();

      await model(
        ModelRequest(
          messages: [
            Message(
              role: Role.system,
              content: [TextPart(text: 'Be helpful.')],
            ),
            Message(
              role: Role.user,
              content: [TextPart(text: 'Hello')],
            ),
          ],
        ),
      );

      // System message should be passed via createChat, not prepended to user message.
      expect(fakeChat.receivedMessages, hasLength(1));
      expect(fakeChat.receivedMessages[0].text, 'Hello');
    });

    test(
      'throws on system-only messages (no user or model messages)',
      () async {
        fakeChat.blockingResponse = const gemma.TextResponse('ok');
        final model = buildModel();

        await expectLater(
          model(
            ModelRequest(
              messages: [
                Message(
                  role: Role.system,
                  content: [TextPart(text: 'Be helpful.')],
                ),
              ],
            ),
          ),
          throwsA(isA<GenkitException>()),
        );
      },
    );
  });
}
