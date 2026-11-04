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

    test('a refusal found at the first send is UNIMPLEMENTED', () async {
      fakeModel
        ..structuredSupport = enforcesAll
        ..newSession = () => FakeStructuredSession()
          ..startError = const gemma.ResponseFormatUnsupportedException(
            'The constraint compiler rejected the schema.',
          );

      await expectLater(
        buildModel()(request()),
        throwsA(
          isA<GenkitException>()
              .having((e) => e.status, 'status', StatusCode.unimplemented)
              .having(
                (e) => e.cause,
                'cause',
                isA<gemma.ResponseFormatUnsupportedException>(),
              ),
        ),
      );
    });
  });

  group('a failed structured turn', () {
    setUp(() => fakeModel.structuredSupport = enforcesAll);

    for (final (tokens, end, status) in [
      (['{"backend": '], gemma.TurnEnd.outputLimit, StatusCode.outOfRange),
      (
        ['{"backend": '],
        gemma.TurnEnd.contextLimit,
        StatusCode.resourceExhausted,
      ),
      (['{"backend": "gpu"}'], gemma.TurnEnd.closed, StatusCode.unavailable),
      (['{"backend": '], gemma.TurnEnd.stopped, StatusCode.aborted),
      // Not a value of the enum: the engine did not enforce what it accepted.
      (
        ['{"backend": "tpu"}'],
        gemma.TurnEnd.endOfSequence,
        StatusCode.internal,
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
  });
}
