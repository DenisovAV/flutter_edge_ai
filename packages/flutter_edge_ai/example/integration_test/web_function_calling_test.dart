/// Function calling on the `.litertlm` WEB path — the five cases
/// `gemma4_function_calling_test.dart` runs natively, ported verbatim so the two
/// can be compared directly.
///
/// Why it exists: the core README said web has no function calling. It had none
/// because the BASE `createChat` never passed `tools` to its `sessionCreator`,
/// while `FfiInferenceModel` overrides `createChat` and does — so native worked
/// and every engine inheriting the base silently did not. For Gemma 4 that is
/// invisible twice over: `SdkPassthroughFunctionCallFormat` sets
/// `runtimeInjectsToolDeclarations = true`, so `InferenceChat` deliberately does
/// not weave a text tools prompt either. Neither path carried the tools.
///
/// One passing prompt would not settle it: `flutter_edge_ai_agent`'s README
/// reports that this runtime emits tool-call tokens INCONSISTENTLY. Five cases
/// including a negative control are the minimum that can distinguish "works"
/// from "worked once".
///
/// Run: chromedriver --port=4444 & ; from example/
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/web_function_calling_test.dart -d web-server
///
/// `-d web-server`, not `-d chrome`: the chrome device hangs on "Waiting for
/// connection from debug service" on Flutter 3.47.2 + Chrome 152.
@TestOn('chrome')
library;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _webModelUrl =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm';

const _hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

const _changeColorTool = Tool(
  name: 'change_color',
  description: 'Change the UI background color.',
  parameters: {
    'type': 'object',
    'properties': {
      'color': {
        'type': 'string',
        'description': 'A color name like red, blue, green.',
      },
    },
    'required': ['color'],
  },
);

const _setVolumeTool = Tool(
  name: 'set_volume',
  description: 'Set the audio output volume.',
  parameters: {
    'type': 'object',
    'properties': {
      'level': {
        'type': 'integer',
        'description': 'Volume level from 0 (mute) to 100 (max).',
      },
    },
    'required': ['level'],
  },
);

InferenceModel? _model;
bool _enginesRegistered = false;

/// Anything that can throw lives in a test body, never in setUp: under
/// `flutter drive` a throwing setUp is reported as "All tests passed", because
/// package:integration_test only writes a result from inside `runTest`.
Future<InferenceModel> _ensureModel() async {
  if (!_enginesRegistered) {
    await registerTestEngines();
    _enginesRegistered = true;
  }
  if (_model != null) return _model!;
  await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      )
      .fromNetwork(_webModelUrl, token: _hfToken.isEmpty ? null : _hfToken)
      .install();
  return _model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
}

/// `supportsFunctionCalls` and `modelType` are both load-bearing: without the
/// first, `chat.dart` drops the tools with a warning; without the second,
/// `runtimeInjectsToolDeclarations` cannot be derived from the format.
///
/// Every caller MUST close the returned chat. The web model owns ONE session,
/// so a chat left open poisons the next one: a second `createChat` lands on a
/// conversation still in the previous constrained-decoding state and the engine
/// throws `Invalid token at state 37` / `Task failed with state: 7` rather than
/// degrading. Measured — cases 2-5 all failed that way until this was added.
Future<InferenceChat> _openChat(
  InferenceModel model, {
  List<Tool> tools = const [_changeColorTool],
}) => model.createChat(
  tools: tools,
  supportsFunctionCalls: true,
  modelType: ModelType.gemma4,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('web function calling (@litert-lm/core 0.17.1)', () {
    tearDownAll(() async {
      await _model?.close();
      _model = null;
    });

    testWidgets('1. single tool call yields FunctionCallResponse', (
      tester,
    ) async {
      final chat = await _openChat(await _ensureModel());
      try {
        await chat.addQueryChunk(
          const Message(text: 'Make the background red.', isUser: true),
        );
        final response = await chat.generateChatResponse();

        expect(
          response,
          isA<FunctionCallResponse>(),
          reason: 'got ${response.runtimeType}: $response',
        );
        final fc = response as FunctionCallResponse;
        expect(fc.name, equals('change_color'));
        expect(fc.args['color']?.toString().toLowerCase(), contains('red'));
        expect(
          fc.args.values.any((v) => v.toString().contains('<|"|>')),
          isFalse,
          reason: 'escape tokens must be stripped before reaching the consumer',
        );
      } finally {
        await chat.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('2. multi-tool prompt invokes at least one declared tool', (
      tester,
    ) async {
      final chat = await _openChat(
        await _ensureModel(),
        tools: const [_changeColorTool, _setVolumeTool],
      );
      try {
        await chat.addQueryChunk(
          const Message(
            text: 'Set the background to blue and the volume to 30.',
            isUser: true,
          ),
        );
        final response = await chat.generateChatResponse();

        // Two blocks (parallel) or one (sequential preference) are both valid.
        final calls = switch (response) {
          ParallelFunctionCallResponse(:final calls) => calls,
          FunctionCallResponse() => [response],
          _ => <FunctionCallResponse>[],
        };
        expect(
          calls,
          isNotEmpty,
          reason: 'got ${response.runtimeType}: $response',
        );
        expect(
          calls.map((c) => c.name).toSet().intersection({
            'change_color',
            'set_volume',
          }),
          isNotEmpty,
        );
      } finally {
        await chat.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('3. streaming surfaces the call and leaks no raw tokens', (
      tester,
    ) async {
      final chat = await _openChat(await _ensureModel());
      try {
        await chat.addQueryChunk(
          const Message(text: 'Switch the background to green.', isUser: true),
        );

        final events = <ModelResponse>[];
        await tester.runAsync(() async {
          await for (final e in chat.generateChatResponseAsync()) {
            events.add(e);
          }
        });

        final fnEvents = events.whereType<FunctionCallResponse>().toList();
        expect(
          fnEvents,
          isNotEmpty,
          reason:
              'no FunctionCallResponse among ${events.length} events; types: '
              '${events.map((e) => e.runtimeType).toSet().toList()}',
        );
        expect(fnEvents.first.name, equals('change_color'));

        final textOut = events
            .whereType<TextResponse>()
            .map((t) => t.token)
            .join();
        expect(
          textOut.contains('<|tool_call>') || textOut.contains('<tool_call|>'),
          isFalse,
          reason: 'raw tool_call tokens must not reach the text stream',
        );
      } finally {
        await chat.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('4. negative control: a non-action prompt calls nothing', (
      tester,
    ) async {
      // The case that separates "function calling works" from "the model calls a
      // tool whatever you say". Without it, cases 1-3 are also satisfied by a
      // runtime that fires change_color unconditionally.
      final chat = await _openChat(await _ensureModel());
      try {
        await chat.addQueryChunk(
          const Message(
            text: 'What is the capital of France? Answer in one word.',
            isUser: true,
          ),
        );
        final response = await chat.generateChatResponse();

        expect(
          response,
          isA<TextResponse>(),
          reason: 'got ${response.runtimeType}: $response',
        );
        expect(
          (response as TextResponse).token.toLowerCase(),
          contains('paris'),
        );
      } finally {
        await chat.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('4b. DISCRIMINATOR: plain second turn in a tools chat', (
      tester,
    ) async {
      // Splits the case-5 failure in two. Case 5 dies with "Invalid token at
      // state 37" on the SECOND generation of a tools-enabled chat. That is
      // either (a) the tool-response message specifically, or (b) any second
      // turn while constrained decoding is on. This turn is plain text — no
      // toolResponse — so a failure here means (b) and case 5 is a symptom, not
      // the disease.
      final chat = await _openChat(await _ensureModel());
      try {
        await chat.addQueryChunk(
          const Message(text: 'Make the background red.', isUser: true),
        );
        final first = await chat.generateChatResponse();
        expect(first, isA<FunctionCallResponse>(), reason: 'turn 1: $first');

        await chat.addQueryChunk(
          const Message(text: 'Thanks. Say OK.', isUser: true),
        );
        final second = await chat.generateChatResponse();

        expect(
          second,
          anyOf(isA<TextResponse>(), isA<FunctionCallResponse>()),
          reason: 'turn 2 (plain text, no toolResponse): $second',
        );
      } finally {
        await chat.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('4c. DISCRIMINATOR: second turn when turn 1 called nothing', (
      tester,
    ) async {
      // 4b showed any second turn dies in a tools chat. This narrows it further:
      // tools are declared (so constrained decoding is ON) but turn 1 is a
      // question that needs no tool, so no <|tool_call> is emitted.
      //   passes -> the poison is EMITTING a call; the grammar does not reset
      //             after one, and only tool-calling conversations are ruined.
      //   fails  -> the poison is the FLAG itself; any tools chat is single-turn
      //             on web whether or not a tool is ever used.
      final chat = await _openChat(await _ensureModel());
      try {
        await chat.addQueryChunk(
          const Message(
            text: 'What is the capital of France? Answer in one word.',
            isUser: true,
          ),
        );
        final first = await chat.generateChatResponse();
        expect(first, isA<TextResponse>(), reason: 'turn 1: $first');

        await chat.addQueryChunk(
          const Message(text: 'And the capital of Italy?', isUser: true),
        );
        final second = await chat.generateChatResponse();

        expect(
          second,
          isA<TextResponse>(),
          reason: 'turn 2 after a no-call turn 1: $second',
        );
      } finally {
        await chat.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('5. tool result fed back produces a reply, not a crash', (
      tester,
    ) async {
      final chat = await _openChat(await _ensureModel());
      try {
        await chat.addQueryChunk(
          const Message(text: 'Make the background purple.', isUser: true),
        );
        final first = await chat.generateChatResponse();
        expect(
          first,
          isA<FunctionCallResponse>(),
          reason: 'turn 1 got ${first.runtimeType}: $first',
        );

        await chat.addQueryChunk(
          Message.toolResponse(
            toolName: (first as FunctionCallResponse).name,
            response: const {'status': 'success', 'applied_color': 'purple'},
          ),
        );
        final reply = await chat.generateChatResponse();

        // Natural-language confirmation or another tool call are both valid; what
        // matters is that the round-trip completes and no role markers leak.
        if (reply is TextResponse) {
          expect(reply.token.trim(), isNotEmpty);
          expect(
            reply.token.contains('<|tool_response>') ||
                reply.token.contains('<tool_response|>'),
            isFalse,
          );
        } else {
          expect(reply, isA<FunctionCallResponse>(), reason: '$reply');
        }
      } finally {
        await chat.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
