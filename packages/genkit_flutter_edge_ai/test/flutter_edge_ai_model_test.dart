import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_edge_ai/src/flutter_edge_ai_model.dart';
import 'package:genkit_flutter_edge_ai/src/flutter_edge_ai_options.dart';

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
    return createFlutterEdgeAiModel(
      name: 'flutter-edge-ai/test-model',
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

  group('createFlutterEdgeAiModel', () {
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
          toolChoice: ToolChoice.required, // top-level native field, not config
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
          toolChoice: ToolChoice.none,
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
            StatusCode.invalidArgument,
          ),
        ),
      );
    });

    // The generated getters cast lazily; read outside the parse try, a wrong
    // type escaped as a TypeError, which a hybrid router treats as transient.
    for (final (field, value) in [
      ('temperature', '0.7'),
      ('maxTokens', 'big'),
      ('supportImage', 'yes'),
      ('toolChoice', 1),
      ('preferredAudioBackend', 2),
    ]) {
      test('a wrong type for $field is INVALID_ARGUMENT', () async {
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
              config: {field: value},
            ),
          ),
          throwsA(
            isA<GenkitException>().having(
              (e) => e.status,
              'status',
              StatusCode.invalidArgument,
            ),
          ),
        );
      });
    }

    for (final field in [
      'maxTokens',
      'topK',
      'randomSeed',
      'maxFunctionBufferLength',
    ]) {
      test('a fractional $field is INVALID_ARGUMENT', () async {
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
              config: {field: 0.9},
            ),
          ),
          throwsA(
            isA<GenkitException>().having(
              (e) => e.status,
              'status',
              StatusCode.invalidArgument,
            ),
          ),
        );
      });
    }

    test('an integral double such as 2048.0 is accepted', () async {
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
          config: {'maxFunctionBufferLength': 2048.0},
        ),
      );

      expect(fakeModel.lastMaxFunctionBufferLength, 2048);
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

    test('FlutterEdgeAiModelOptions round-trips backend strings', () {
      final json = FlutterEdgeAiModelOptions(
        preferredBackend: 'npu',
        preferredVisionBackend: 'gpu',
        preferredAudioBackend: 'cpu',
      ).toJson();

      expect(json['preferredBackend'], 'npu');
      expect(json['preferredVisionBackend'], 'gpu');
      expect(json['preferredAudioBackend'], 'cpu');

      final parsed = FlutterEdgeAiModelOptions.fromJson(json);
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

  group('cancellation', () {
    test(
      'cancelling mid-generation stops decoding and aborts the turn',
      () async {
        fakeChat.generationGate = Completer<void>();
        final controller = CancellationController();
        final model = buildModel();

        final call = model(simpleRequest(), cancel: controller.token);
        while (fakeChat.addQueryChunkCallCount == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        controller.cancel();

        await expectLater(call, throwsA(isA<CancelledException>()));
        expect(fakeChat.stopGenerationCallCount, 1);
      },
    );

    test(
      'a request cancelled while waiting for the lock opens no chat',
      () async {
        fakeChat.generationGate = Completer<void>();
        final controller = CancellationController();
        final model = buildModel();

        final first = model(simpleRequest('first'));
        while (fakeChat.addQueryChunkCallCount == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        final second = expectLater(
          model(simpleRequest('second'), cancel: controller.token),
          throwsA(isA<CancelledException>()),
        );
        controller.cancel();
        fakeChat.generationGate!.complete();

        await first;
        await second;
        expect(fakeModel.createChatCallCount, 1);
      },
    );

    test('a request cancelled in the queue returns at once and keeps its '
        'place', () async {
      fakeChat.generationGate = Completer<void>();
      final controller = CancellationController();
      final model = buildModel();

      final first = model(simpleRequest('first'));
      while (fakeChat.addQueryChunkCallCount == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      var secondSettled = false;
      final second = model(simpleRequest('second'), cancel: controller.token)
          .then<void>(
            (_) {},
            onError: (Object e) {
              expect(e, isA<CancelledException>());
              secondSettled = true;
            },
          );
      final third = model(simpleRequest('third'));
      controller.cancel();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(secondSettled, isTrue, reason: 'it waited for the turn ahead');
      expect(
        fakeChat.addQueryChunkCallCount,
        1,
        reason: 'the request behind it overtook the running generation',
      );

      fakeChat.generationGate!.complete();
      await Future.wait([first, second, third]);
      expect(fakeChat.addQueryChunkCallCount, 2);
    });

    test('the next request starts only after the stop has landed', () async {
      fakeChat.generationGate = Completer<void>();
      fakeChat.stopLanding = Completer<void>();
      final controller = CancellationController();
      final model = buildModel();

      final first = model(simpleRequest('first'), cancel: controller.token);
      while (fakeChat.addQueryChunkCallCount == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final second = model(simpleRequest('second'));
      controller.cancel();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        fakeChat.addQueryChunkCallCount,
        1,
        reason: 'a stop still in flight could cut the next request short',
      );

      fakeChat.stopLanding!.complete();
      await expectLater(first, throwsA(isA<CancelledException>()));
      await second;
      expect(fakeChat.addQueryChunkCallCount, 2);
    });

    test('a stop requested while a failed turn unwinds lands first', () async {
      // The cancel arrives at every microtask depth while the failed
      // generation unwinds, so it also hits the window between the failure
      // and the release of the lock.
      void after(int hops, void Function() action) => hops == 0
          ? action()
          : scheduleMicrotask(() => after(hops - 1, action));

      for (var depth = 0; depth < 16; depth++) {
        final chat = FakeInferenceChat()
          ..generationError = StateError('boom')
          ..stopLanding = Completer<void>();
        final controller = CancellationController();
        chat.onGenerate = () {
          if (chat.generationError != null) after(depth, controller.cancel);
        };
        final model = createFlutterEdgeAiModel(
          name: 'flutter-edge-ai/test-model',
          modelType: gemma.ModelType.gemmaIt,
          fileType: gemma.ModelFileType.task,
          runtime: FakeRuntime(
            model: FakeInferenceModel()..chatToReturn = chat,
          ),
        );

        // Listen at once: the failed turn may finish while the loop below runs.
        final firstOutcome = expectLater(
          model(simpleRequest('first'), cancel: controller.token),
          throwsA(anything),
        );
        final second = model(simpleRequest('second'));
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        if (chat.stopGenerationCallCount > 0) {
          expect(
            chat.addQueryChunkCallCount,
            1,
            reason:
                'depth $depth: the next request started while a stop '
                'was still in flight',
          );
        }

        chat.stopLanding!.complete();
        await firstOutcome;
        await second;
      }
    });

    test('a stop that fails is reported to the caller', () async {
      fakeChat.generationGate = Completer<void>();
      fakeChat.stopError = StateError('stop failed');
      final controller = CancellationController();
      final model = buildModel();

      final call = model(simpleRequest(), cancel: controller.token);
      while (fakeChat.addQueryChunkCallCount == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.cancel();

      await expectLater(call, throwsA(isA<StateError>()));
    });
  });
}
