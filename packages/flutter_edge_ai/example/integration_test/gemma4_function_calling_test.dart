// End-to-end integration tests for Gemma 4 native function calling.
//
// Verifies the Phase 1-4 wiring (chat.dart → FFI → SDK → minja → model →
// SDK → chat.dart) on real `gemma-4-E2B-it.litertlm` running with macOS GPU.
//
// Coverage:
// 1. Single tool call (sync `generateChatResponse`) — base happy path.
// 2. Parallel tool calls — model picks up two unrelated tools at once.
// 3. Streaming (`generateChatResponseAsync`) — final emission must be a
//    FunctionCallResponse, not text fragments of native tokens.
// 4. Plain-text control — when the user just chats, no tool_calls leak
//    through and we get a TextResponse.
// 5. Multi-turn round-trip — tool result fed back via
//    `Message.toolResponse` produces a natural-language assistant reply
//    (no `<|tool_response>` leakage to the consumer).
//
// Run: cd example && flutter test integration_test/gemma4_function_calling_test.dart -d macos

import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _gemma4Path =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/gemma-4-E2B-it.litertlm';

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

Future<void> _installModel() async {
  await registerTestEngines();
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  ).fromFile(_gemma4Path).install();
}

Future<InferenceModel> _openModel() async => FlutterEdgeAi.getActiveModel(
  maxTokens: 2048,
  preferredBackend: PreferredBackend.gpu,
);

Future<InferenceChat> _openChat(
  InferenceModel model, {
  List<Tool> tools = const [_changeColorTool],
}) async => model.createChat(
  tools: tools,
  supportsFunctionCalls: true,
  modelType: ModelType.gemma4,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    expect(
      File(_gemma4Path).existsSync(),
      isTrue,
      reason: 'Place gemma-4-E2B-it.litertlm at $_gemma4Path',
    );
  });

  testWidgets(
    '1. Single tool call — sync API yields FunctionCallResponse',
    (tester) async {
      await _installModel();
      final model = await _openModel();
      try {
        final chat = await _openChat(model);
        await chat.addQueryChunk(
          const Message(text: 'Make the background red.', isUser: true),
        );
        final response = await chat.generateChatResponse();

        expect(
          response,
          isA<FunctionCallResponse>(),
          reason: 'SDK-parsed tool call must surface as FunctionCallResponse',
        );
        final fc = response as FunctionCallResponse;
        expect(fc.name, equals('change_color'));
        final color = fc.args['color']?.toString() ?? '';
        expect(color.toLowerCase(), contains('red'));
        expect(
          color.contains('<|"|>'),
          isFalse,
          reason: 'Escape tokens must be stripped before reaching consumer',
        );
        // ignore: avoid_print
        print('[1] single tool call OK: ${fc.name} args=${fc.args}');
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    '2. Parallel tool calls — multi-tool prompt yields ParallelFunctionCallResponse or repeats',
    (tester) async {
      await _installModel();
      final model = await _openModel();
      try {
        final chat = await _openChat(
          model,
          tools: const [_changeColorTool, _setVolumeTool],
        );
        await chat.addQueryChunk(
          const Message(
            text: 'Set the background to blue and the volume to 30.',
            isUser: true,
          ),
        );
        final response = await chat.generateChatResponse();

        // Model is allowed to either:
        //   (a) emit two <|tool_call> blocks → ParallelFunctionCallResponse, or
        //   (b) emit just one tool call → FunctionCallResponse (some models prefer
        //       sequential calls). Both shapes are valid; we only assert the call
        //       list contains at least one of the requested tools and no escape
        //       tokens leaked through.
        final calls = <FunctionCallResponse>[];
        if (response is ParallelFunctionCallResponse) {
          calls.addAll(response.calls);
        } else if (response is FunctionCallResponse) {
          calls.add(response);
        } else {
          fail(
            'Expected FunctionCall or ParallelFunctionCall, got '
            '${response.runtimeType}: $response',
          );
        }

        expect(calls, isNotEmpty);
        final names = calls.map((c) => c.name).toSet();
        expect(
          names.intersection({'change_color', 'set_volume'}),
          isNotEmpty,
          reason: 'At least one declared tool should be invoked',
        );
        for (final c in calls) {
          for (final v in c.args.values) {
            expect(
              v.toString().contains('<|"|>'),
              isFalse,
              reason: 'No escape tokens in any arg value',
            );
          }
        }
        // ignore: avoid_print
        print(
          '[2] parallel/multi tool calls OK: ${calls.map((c) => "${c.name}(${c.args})").join(", ")}',
        );
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    '3. Streaming — generateChatResponseAsync yields FunctionCallResponse at end',
    (tester) async {
      await _installModel();
      final model = await _openModel();
      try {
        final chat = await _openChat(model);
        await chat.addQueryChunk(
          const Message(text: 'Switch the background to green.', isUser: true),
        );

        final events = <ModelResponse>[];
        await tester.runAsync(() async {
          await for (final event in chat.generateChatResponseAsync()) {
            events.add(event);
          }
        });

        expect(
          events,
          isNotEmpty,
          reason: 'Stream must yield at least one event',
        );
        // The function call is the contract; text events before it are allowed
        // (model may "think out loud" but must finalize with a tool call).
        final fnEvents = events.whereType<FunctionCallResponse>().toList();
        expect(
          fnEvents,
          isNotEmpty,
          reason:
              'Streaming Gemma 4 must surface SDK tool call as FunctionCallResponse',
        );
        final fc = fnEvents.first;
        expect(fc.name, equals('change_color'));
        final color = fc.args['color']?.toString() ?? '';
        expect(color.toLowerCase(), contains('green'));
        expect(color.contains('<|"|>'), isFalse);

        // No raw native tool tokens should leak into the text stream.
        final textOut = events
            .whereType<TextResponse>()
            .map((t) => t.token)
            .join();
        expect(
          textOut.contains('<|tool_call>'),
          isFalse,
          reason: 'Native tool_call tokens must not leak into text stream',
        );
        expect(
          textOut.contains('<tool_call|>'),
          isFalse,
          reason:
              'Native tool_call close tokens must not leak into text stream',
        );
        // ignore: avoid_print
        print(
          '[3] streaming OK: ${events.length} events, ${fnEvents.length} function call(s)',
        );
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    '4. Plain-text control — non-action prompt yields TextResponse, no tool calls',
    (tester) async {
      await _installModel();
      final model = await _openModel();
      try {
        final chat = await _openChat(model);
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
          reason: 'Non-action prompt must NOT trigger tool call',
        );
        final text = (response as TextResponse).token;
        expect(text.toLowerCase(), contains('paris'));
        expect(text.contains('<|tool_call>'), isFalse);
        expect(text.contains('<|"|>'), isFalse);
        // ignore: avoid_print
        print('[4] plain-text control OK: "${text.trim()}"');
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    '5. Multi-turn round-trip — tool result fed back yields natural reply',
    (tester) async {
      await _installModel();
      final model = await _openModel();
      try {
        final chat = await _openChat(model);

        // Turn 1: user asks → model returns tool call
        await chat.addQueryChunk(
          const Message(text: 'Make the background purple.', isUser: true),
        );
        final toolCallResponse = await chat.generateChatResponse();
        expect(toolCallResponse, isA<FunctionCallResponse>());
        final fc = toolCallResponse as FunctionCallResponse;
        expect(fc.name, equals('change_color'));

        // Turn 2: app executes tool, replies with result. Use Message.toolResponse
        // (factory in core/message.dart) to mark this as role=tool — chat.dart's
        // transformToChatPrompt routes tool-response messages back to the model.
        await chat.addQueryChunk(
          Message.toolResponse(
            toolName: fc.name,
            response: const {'status': 'success', 'applied_color': 'purple'},
          ),
        );
        final replyResponse = await chat.generateChatResponse();

        // Model may (a) speak natural language confirming the action, or
        // (b) issue another tool call (e.g. asking for additional confirmation).
        // Either is valid — both prove the round-trip didn't crash and the
        // reply path doesn't leak tool_response tokens into the consumer.
        if (replyResponse is TextResponse) {
          expect(replyResponse.token.contains('<|tool_response>'), isFalse);
          expect(replyResponse.token.contains('<tool_response|>'), isFalse);
          expect(replyResponse.token.trim(), isNotEmpty);
          // ignore: avoid_print
          print(
            '[5] round-trip OK (text reply): "${replyResponse.token.trim()}"',
          );
        } else if (replyResponse is FunctionCallResponse) {
          // ignore: avoid_print
          print(
            '[5] round-trip OK (model called another tool): ${replyResponse.name}',
          );
        } else {
          fail(
            'Unexpected reply type after tool response: '
            '${replyResponse.runtimeType}',
          );
        }
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
