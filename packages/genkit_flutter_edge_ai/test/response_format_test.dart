import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_edge_ai/src/flutter_edge_ai_model.dart';

import 'src/fake_runtime.dart';

/// Genkit's output schema reaches flutter_edge_ai as the chat's
/// `responseFormat` when the loaded model enforces it, and stays a prompt
/// instruction when it does not. A failed structured turn is a Genkit error
/// whose status decides whether genkit_hybrid tries its next branch.
void main() {
  const schema = {
    'type': 'object',
    'properties': {
      'backend': {
        'type': 'string',
        'enum': ['cpu', 'gpu'],
      },
    },
    'required': ['backend'],
  };
  const enforcesAll = gemma.StructuredOutputSupport(
    keywords: gemma.ResponseFormat.dialect,
  );

  late FakeInferenceModel fakeModel;
  late FakeInferenceChat fakeChat;
  late FakeRuntime runtime;

  setUp(() {
    fakeChat = FakeInferenceChat()
      ..blockingResponse = const gemma.TextResponse('{"backend": "cpu"}');
    fakeModel = FakeInferenceModel()..chatToReturn = fakeChat;
    runtime = FakeRuntime(model: fakeModel);
  });

  Model buildModel() => createFlutterEdgeAiModel(
    name: 'flutter-edge-ai/test-model',
    modelType: gemma.ModelType.gemmaIt,
    fileType: gemma.ModelFileType.task,
    runtime: runtime,
  );

  ModelRequest request({
    Map<String, dynamic>? outputSchema = schema,
    bool constrained = true,
    String? format = 'json',
    List<ToolDefinition>? tools,
    Map<String, dynamic>? config,
  }) => ModelRequest(
    messages: [
      Message(
        role: Role.user,
        content: [TextPart(text: 'Pick a backend.')],
      ),
    ],
    tools: tools,
    config: config,
    output: OutputConfig(
      format: format,
      schema: outputSchema,
      constrained: constrained,
    ),
  );

  String sessionPrompt() =>
      fakeModel.openedSessions.single.received.map((m) => m.text).join('\n');

  group('a model that enforces the schema', () {
    setUp(() => fakeModel.structuredSupport = enforcesAll);

    test('gets it as the chat\'s responseFormat', () async {
      fakeModel.newSession = () =>
          FakeStructuredSession(tokens: ['{"backend": ', '"gpu"}']);

      final response = await buildModel()(request());

      expect(response.finishReason, FinishReason.stop);
      expect(response.message!.text, '{"backend": "gpu"}');
      expect(fakeModel.createChatCallCount, 0);
      final sent = fakeModel.sessionRequests.single.responseFormat;
      expect(sent?.schema, schema);
      // The schema is in the prompt as well: whether the model enforces it
      // is known only once it is loaded.
      expect(sessionPrompt(), contains('Pick a backend.'));
      expect(sessionPrompt(), contains('conform to the following schema'));
      // The chat is closed before the request ends.
      expect(fakeModel.openedSessions.single.closed, isTrue);
    });

    test('streams the value as it is decoded', () async {
      fakeModel.newSession = () =>
          FakeStructuredSession(tokens: ['{"backend": ', '"gpu"}']);
      final chunks = <ModelResponseChunk>[];

      final response = await buildModel()(request(), onChunk: chunks.add);

      expect(chunks.map((c) => c.text), ['{"backend": ', '"gpu"}']);
      expect(response.message!.text, '{"backend": "gpu"}');
      expect(fakeModel.createChatCallCount, 0);
      expect(fakeModel.sessionRequests.single.responseFormat?.schema, schema);
    });

    test('sends the request\'s sampling and limits to openChat', () async {
      fakeModel.newSession = () =>
          FakeStructuredSession(tokens: ['{"backend": "gpu"}']);
      await buildModel()(
        request(
          config: {
            'temperature': 0.3,
            'topK': 7,
            'topP': 0.8,
            'randomSeed': 42,
            'maxOutputTokens': 64,
            'toolChoice': 'required',
          },
        ),
      );

      final sent = fakeModel.sessionRequests.single;
      expect(sent.temperature, 0.3);
      expect(sent.topK, 7);
      expect(sent.topP, 0.8);
      expect(sent.randomSeed, 42);
      expect(sent.maxOutputTokens, 64);
      expect(sent.modelType, gemma.ModelType.gemmaIt);
      // No tools to choose among on the structured path.
      expect(sent.toolChoice, gemma.ToolChoice.auto);
      expect(sent.tools, isEmpty);
      expect(sent.enableThinking, isFalse);
    });

    test('keeps the schema with a configured systemInstruction', () async {
      fakeModel.newSession = () =>
          FakeStructuredSession(tokens: ['{"backend": "gpu"}']);

      await buildModel()(request(config: {'systemInstruction': 'Be brief.'}));

      // Without a system message the schema goes into the user message;
      // the configured instruction is sent as it is.
      expect(fakeModel.sessionRequests.single.systemInstruction, 'Be brief.');
      expect(sessionPrompt(), contains('conform to the following schema'));
    });

    test('passes a multi-turn history to the structured session', () async {
      fakeModel.newSession = () =>
          FakeStructuredSession(tokens: ['{"backend": "gpu"}']);

      await buildModel()(
        ModelRequest(
          messages: [
            Message(
              role: Role.user,
              content: [TextPart(text: 'Which backends are there?')],
            ),
            Message(
              role: Role.model,
              content: [TextPart(text: 'cpu and gpu.')],
            ),
            Message(
              role: Role.user,
              content: [TextPart(text: 'Pick one.')],
            ),
          ],
          output: OutputConfig(
            format: 'json',
            schema: schema,
            constrained: true,
          ),
        ),
      );

      final received = fakeModel.openedSessions.single.received;
      expect(received.map((m) => m.isUser), [true, false, true]);
      expect(received.first.text, 'Which backends are there?');
      expect(received[1].text, 'cpu and gpu.');
      expect(received.last.text, startsWith('Pick one.'));
    });

    for (final (what, build) in <(String, ModelRequest Function())>[
      (
        'a request with tools',
        () => request(
          tools: [
            ToolDefinition(
              name: 'lookup',
              description: 'Looks a backend up.',
              inputSchema: const {'type': 'object'},
            ),
          ],
        ),
      ),
      (
        'a request with thinking',
        () => request(config: {'enableThinking': true}),
      ),
      ('an unconstrained request', () => request(constrained: false)),
      ('a format other than JSON', () => request(format: 'text')),
      (
        'a schema outside the dialect\'s rules',
        () => request(
          outputSchema: const {
            'type': ['object', 'null'],
          },
        ),
      ),
    ]) {
      test('$what is sent without a format', () async {
        await buildModel()(build());

        expect(fakeModel.createChatCallCount, 1);
        expect(fakeModel.sessionRequests, isEmpty);
      });
    }
  });

  group('a model that refuses the schema', () {
    test('every engine today: the schema stays in the prompt', () async {
      final response = await buildModel()(request());

      expect(response.message!.text, '{"backend": "cpu"}');
      expect(fakeModel.createChatCallCount, 1);
      expect(fakeModel.sessionRequests, isEmpty);
      expect(
        fakeChat.receivedMessages.map((m) => m.text).join('\n'),
        contains('conform to the following schema'),
      );
    });

    test(
      'a keyword it does not enforce: the schema stays in the prompt',
      () async {
        fakeModel.structuredSupport = const gemma.StructuredOutputSupport(
          keywords: {'type', 'properties', 'required'},
        );

        await buildModel()(request());

        expect(fakeModel.createChatCallCount, 1);
        expect(fakeModel.sessionRequests, isEmpty);
      },
    );

    for (final streaming in [false, true]) {
      test('a refusal at the first send${streaming ? ', streamed,' : ''} '
          'runs the request again prompt-only', () async {
        final rejected = FakeStructuredSession()
          ..startError = const gemma.ResponseFormatUnsupportedException(
            'The constraint compiler rejected the schema.',
          );
        fakeModel
          ..structuredSupport = enforcesAll
          ..newSession = () => rejected;
        final chunks = <ModelResponseChunk>[];

        final response = await buildModel()(
          request(),
          onChunk: streaming ? chunks.add : null,
        );

        // The prompt-only chat's answer, the failed session closed.
        expect(response.message!.text, '{"backend": "cpu"}');
        expect(rejected.closed, isTrue);
        expect(fakeModel.openedSessions, [rejected]);
        expect(fakeModel.createChatCallCount, 1);
        expect(fakeChat.closeCallCount, 1);
        expect(
          fakeChat.receivedMessages.map((m) => m.text).join('\n'),
          contains('conform to the following schema'),
        );
        if (streaming) {
          expect(chunks.map((c) => c.text).join(), '{"backend": "cpu"}');
        }
      });
    }

    test('a refusal after a chunk reached the caller is not retried', () async {
      fakeModel
        ..structuredSupport = enforcesAll
        ..newSession = () =>
            FakeStructuredSession(tokens: ['{"backend": ', '"gpu"}'])
              ..errorAfterFirst =
                  const gemma.ResponseFormatUnsupportedException(
                    'Rejected mid-turn.',
                  );
      final chunks = <ModelResponseChunk>[];

      await expectLater(
        buildModel()(request(), onChunk: chunks.add),
        throwsA(
          isA<GenkitException>().having(
            (e) => e.status,
            'status',
            StatusCode.failedPrecondition,
          ),
        ),
      );
      expect(chunks, hasLength(1));
      expect(fakeModel.createChatCallCount, 0);
      expect(fakeModel.openedSessions.single.closed, isTrue);
    });

    test('a refusal thrown by openChat itself runs prompt-only', () async {
      fakeModel
        ..structuredSupport = enforcesAll
        // refusalFor accepts; openChat's own check refuses.
        ..refusal = (call) => call == 1
            ? null
            : const gemma.ResponseFormatUnsupportedException('Not now.');

      final response = await buildModel()(request());

      expect(response.message!.text, '{"backend": "cpu"}');
      expect(fakeModel.refusalCalls, 2);
      expect(fakeModel.sessionRequests, isEmpty);
      expect(fakeModel.createChatCallCount, 1);
    });

    test('an engine that claims keywords outside the dialect fails the '
        'request with FAILED_PRECONDITION', () async {
      fakeModel.structuredSupport = const gemma.StructuredOutputSupport(
        keywords: {'type', 'pattern'},
      );

      await expectLater(
        buildModel()(request()),
        throwsA(
          isA<GenkitException>().having(
            (e) => e.status,
            'status',
            StatusCode.failedPrecondition,
          ),
        ),
      );
      expect(fakeModel.createChatCallCount, 0);
    });
  });

  group('a failed structured turn', () {
    setUp(() => fakeModel.structuredSupport = enforcesAll);

    for (final (tokens, end, status) in [
      (['{"backend": '], gemma.TurnEnd.outputLimit, StatusCode.outOfRange),
      (['{"backend": '], gemma.TurnEnd.contextLimit, StatusCode.outOfRange),
      (['{"backend": "gpu"}'], gemma.TurnEnd.closed, StatusCode.aborted),
      (['{"backend": '], gemma.TurnEnd.stopped, StatusCode.aborted),
      // Not a value of the enum: the engine did not enforce what it accepted.
      (
        ['{"backend": "tpu"}'],
        gemma.TurnEnd.endOfSequence,
        StatusCode.failedPrecondition,
      ),
    ]) {
      for (final streaming in [false, true]) {
        test(
          '${end.name}${streaming ? ', streamed,' : ''} is ${status.wireName}',
          () async {
            fakeModel.newSession = () =>
                FakeStructuredSession(tokens: tokens, end: end);

            await expectLater(
              buildModel()(request(), onChunk: streaming ? (_) {} : null),
              throwsA(
                isA<GenkitException>()
                    .having((e) => e.status, 'status', status)
                    .having(
                      (e) => e.cause,
                      'cause',
                      isA<gemma.StructuredOutputException>(),
                    ),
              ),
            );
            expect(fakeModel.openedSessions.single.closed, isTrue);
          },
        );
      }
    }

    for (final streaming in [false, true]) {
      test('stopped by the caller\'s cancel${streaming ? ', streamed,' : ''} '
          'is the cancel', () async {
        final session = FakeStructuredSession(
          tokens: ['{"backend": ', '"gpu"}'],
        )..gate = Completer<void>();
        fakeModel.newSession = () => session;
        final controller = CancellationController();

        final call = buildModel()(
          request(),
          cancel: controller.token,
          onChunk: streaming ? (_) {} : null,
        );
        while (session.turns == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        controller.cancel();

        await expectLater(call, throwsA(isA<CancelledException>()));
        expect(session.stops, 1);
        expect(session.closed, isTrue);
      });
    }

    Future<Object?> cancelMidTurn(FakeStructuredSession session) async {
      fakeModel.newSession = () => session;
      final controller = CancellationController();
      final call = buildModel()(request(), cancel: controller.token);
      while (session.turns == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.cancel();
      try {
        await call;
        return null;
      } catch (e) {
        return e;
      }
    }

    test('a cancel that raced another end is still the cancel', () async {
      final session =
          FakeStructuredSession(
              tokens: ['{"backend": ', '"gpu"}'],
              end: gemma.TurnEnd.outputLimit,
            )
            ..gate = Completer<void>()
            ..endIgnoresStop = true;

      expect(await cancelMidTurn(session), isA<CancelledException>());
      expect(session.stops, 1);
    });

    test('a non-conforming reply under a cancel is still reported', () async {
      // The engine ended normally on a cut value: its bug, which a cancel
      // must not hide.
      final session = FakeStructuredSession(tokens: ['{"backend": ', '"gpu"}'])
        ..gate = Completer<void>()
        ..endIgnoresStop = true;

      expect(
        await cancelMidTurn(session),
        isA<GenkitException>().having(
          (e) => e.status,
          'status',
          StatusCode.failedPrecondition,
        ),
      );
    });
  });
}
