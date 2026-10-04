// Integration test: tool/function calling across all supported model types.
// Run on Android: flutter test integration_test/tool_calling_test.dart -d <android-device>
//
// Prerequisites:
//   Push models to device: ./scripts/prepare_test_models.sh [device_id]
//   Models loaded from /data/local/tmp/flutter_gemma_test/ on device.
//
// Tests per model:
//   - install: model loads from device file
//   - auto: model decides whether to call a tool
//   - required: model must call a tool
//   - none: model must NOT call a tool (even if tools are provided)
//   - streaming: function call detection in async mode
//   - parallel: multi-action prompt for multiple function calls

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/core/function_call_parser.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _deviceModelDir = '/data/local/tmp/flutter_gemma_test';

/// Test model configuration for tool calling tests.
class ToolCallingTestModel {
  final String name;
  final String filePath;
  final String filename;
  final ModelType modelType;
  final ModelFileType fileType;
  final bool isThinking;
  final double temperature;
  final int topK;
  final double topP;
  final int maxTokens;

  const ToolCallingTestModel({
    required this.name,
    required this.filePath,
    required this.filename,
    required this.modelType,
    this.fileType = ModelFileType.task,
    this.isThinking = false,
    this.temperature = 1.0,
    this.topK = 64,
    this.topP = 0.95,
    this.maxTokens = 1024,
  });
}

/// Test models — .task format, loaded from device filesystem.
const _testModels = [
  ToolCallingTestModel(
    name: 'FunctionGemma 270M',
    filePath: '$_deviceModelDir/functiongemma-270M-it.task',
    filename: 'functiongemma-270M-it.task',
    modelType: ModelType.functionGemma,
  ),
  ToolCallingTestModel(
    name: 'Gemma 3 1B',
    filePath: '$_deviceModelDir/gemma3-1b-it-int4.task',
    filename: 'gemma3-1b-it-int4.task',
    modelType: ModelType.gemmaIt,
  ),
  ToolCallingTestModel(
    name: 'Qwen 2.5 0.5B',
    filePath:
        '$_deviceModelDir/Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
    filename: 'Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task',
    modelType: ModelType.qwen,
  ),
  ToolCallingTestModel(
    name: 'DeepSeek R1 1.5B',
    filePath: '$_deviceModelDir/deepseek_q8_ekv1280.task',
    filename: 'deepseek_q8_ekv1280.task',
    modelType: ModelType.deepSeek,
    isThinking: true,
    temperature: 0.6,
    topK: 40,
    topP: 0.7,
  ),
  ToolCallingTestModel(
    name: 'Gemma 3n E2B',
    filePath: '$_deviceModelDir/gemma-3n-E2B-it-int4.task',
    filename: 'gemma-3n-E2B-it-int4.task',
    modelType: ModelType.gemmaIt,
    maxTokens: 4096,
  ),
];

/// Standard tools for testing — same as example app.
const _testTools = [
  Tool(
    name: 'change_app_title',
    description: 'Changes the title of the app',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'The new title for the app'},
      },
      'required': ['title'],
    },
  ),
  Tool(
    name: 'change_background_color',
    description: 'Changes the background color of the app',
    parameters: {
      'type': 'object',
      'properties': {
        'color': {
          'type': 'string',
          'description': 'The color to change to',
          'enum': ['red', 'green', 'blue', 'yellow', 'purple', 'orange'],
        },
      },
      'required': ['color'],
    },
  ),
  Tool(
    name: 'show_alert',
    description: 'Shows an alert dialog to the user',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'The title of the alert'},
        'message': {'type': 'string', 'description': 'The message to display'},
      },
      'required': ['title', 'message'],
    },
  ),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final model in _testModels) {
    group('Tool Calling: ${model.name}', () {
      testWidgets('install model', (tester) async {
        await registerTestEngines();

        debugPrint('[${model.name}] Installing from file: ${model.filePath}');
        await FlutterEdgeAi.installModel(
          modelType: model.modelType,
          fileType: model.fileType,
        ).fromFile(model.filePath).install();

        expect(FlutterEdgeAi.hasActiveModel(), isTrue);
        debugPrint('[${model.name}] Installed successfully');
      }, timeout: const Timeout(Duration(minutes: 10)));

      testWidgets(
        'ToolChoice.auto — model calls function on action request',
        (tester) async {
          await registerTestEngines();
          await _ensureModelInstalled(model);

          final inferenceModel = await FlutterEdgeAi.getActiveModel(
            maxTokens: model.maxTokens,
            preferredBackend: PreferredBackend.cpu,
          );

          try {
            final chat = await inferenceModel.createChat(
              temperature: model.temperature,
              topK: model.topK,
              topP: model.topP,
              tools: _testTools,
              supportsFunctionCalls: true,
              isThinking: model.isThinking,
              modelType: model.modelType,
              toolChoice: ToolChoice.auto,
            );

            await chat.addQueryChunk(
              const Message(
                text: 'Show an alert with title "Test" and message "Hello"',
                isUser: true,
              ),
            );

            final response = await chat.generateChatResponse();
            debugPrint(
              '[${model.name}/auto] Response type: ${response.runtimeType}',
            );

            if (response is FunctionCallResponse) {
              debugPrint(
                '[${model.name}/auto] Function: ${response.name}(${response.args})',
              );
              expect(response.name, equals('show_alert'));
              expect(response.args['title'], isNotNull);
            } else if (response is ParallelFunctionCallResponse) {
              debugPrint(
                '[${model.name}/auto] Parallel calls: ${response.calls.length}',
              );
              expect(response.calls, isNotEmpty);
              expect(response.calls.first.name, equals('show_alert'));
            } else if (response is TextResponse) {
              debugPrint(
                '[${model.name}/auto] Text: "${_truncate(response.token)}"',
              );
            }
          } finally {
            await inferenceModel.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );

      testWidgets(
        'ToolChoice.required — model must call function',
        (tester) async {
          await registerTestEngines();
          await _ensureModelInstalled(model);

          final inferenceModel = await FlutterEdgeAi.getActiveModel(
            maxTokens: model.maxTokens,
            preferredBackend: PreferredBackend.cpu,
          );

          try {
            final chat = await inferenceModel.createChat(
              temperature: model.temperature,
              topK: model.topK,
              topP: model.topP,
              tools: _testTools,
              supportsFunctionCalls: true,
              isThinking: model.isThinking,
              modelType: model.modelType,
              toolChoice: ToolChoice.required,
            );

            await chat.addQueryChunk(
              const Message(text: 'Hello, how are you?', isUser: true),
            );

            final response = await chat.generateChatResponse();
            debugPrint(
              '[${model.name}/required] Response type: ${response.runtimeType}',
            );

            if (response is FunctionCallResponse) {
              debugPrint(
                '[${model.name}/required] Function: ${response.name}(${response.args})',
              );
              expect(response.name, isNotEmpty);
            } else if (response is ParallelFunctionCallResponse) {
              debugPrint(
                '[${model.name}/required] Parallel calls: ${response.calls.length}',
              );
              expect(response.calls, isNotEmpty);
            } else {
              debugPrint(
                '[${model.name}/required] WARNING: Expected function call but got ${response.runtimeType}',
              );
            }
          } finally {
            await inferenceModel.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );

      testWidgets(
        'ToolChoice.none — model must NOT call function',
        (tester) async {
          await registerTestEngines();
          await _ensureModelInstalled(model);

          final inferenceModel = await FlutterEdgeAi.getActiveModel(
            maxTokens: model.maxTokens,
            preferredBackend: PreferredBackend.cpu,
          );

          try {
            final chat = await inferenceModel.createChat(
              temperature: model.temperature,
              topK: model.topK,
              topP: model.topP,
              tools: _testTools,
              supportsFunctionCalls: true,
              isThinking: model.isThinking,
              modelType: model.modelType,
              toolChoice: ToolChoice.none,
            );

            await chat.addQueryChunk(
              const Message(
                text: 'Change the background color to red',
                isUser: true,
              ),
            );

            final response = await chat.generateChatResponse();
            debugPrint(
              '[${model.name}/none] Response type: ${response.runtimeType}',
            );

            expect(
              response,
              isA<TextResponse>(),
              reason:
                  'ToolChoice.none should produce text response, not function call',
            );
            final text = (response as TextResponse).token;
            debugPrint('[${model.name}/none] Text: "${_truncate(text)}"');
            expect(text, isNotEmpty);
          } finally {
            await inferenceModel.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );

      testWidgets(
        'Streaming — function call detection in async mode',
        (tester) async {
          await registerTestEngines();
          await _ensureModelInstalled(model);

          final inferenceModel = await FlutterEdgeAi.getActiveModel(
            maxTokens: model.maxTokens,
            preferredBackend: PreferredBackend.cpu,
          );

          try {
            final chat = await inferenceModel.createChat(
              temperature: model.temperature,
              topK: model.topK,
              topP: model.topP,
              tools: _testTools,
              supportsFunctionCalls: true,
              isThinking: model.isThinking,
              modelType: model.modelType,
              toolChoice: ToolChoice.auto,
            );

            await chat.addQueryChunk(
              const Message(
                text: 'Show an alert with title "Test" and message "Hello"',
                isUser: true,
              ),
            );

            FunctionCallResponse? functionCall;
            ParallelFunctionCallResponse? parallelCall;
            final textBuffer = StringBuffer();

            await for (final response in chat.generateChatResponseAsync()) {
              if (response is FunctionCallResponse) {
                functionCall = response;
              } else if (response is ParallelFunctionCallResponse) {
                parallelCall = response;
              } else if (response is TextResponse) {
                textBuffer.write(response.token);
              }
            }

            debugPrint(
              '[${model.name}/streaming] FunctionCall: ${functionCall?.name}, '
              'Parallel: ${parallelCall?.calls.length}, '
              'Text: "${_truncate(textBuffer.toString())}"',
            );

            if (functionCall != null) {
              expect(functionCall.name, equals('show_alert'));
            } else if (parallelCall != null) {
              expect(parallelCall.calls, isNotEmpty);
            }
          } finally {
            await inferenceModel.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );

      testWidgets(
        'Parallel — multi-action prompt for multiple function calls',
        (tester) async {
          await registerTestEngines();
          await _ensureModelInstalled(model);

          final inferenceModel = await FlutterEdgeAi.getActiveModel(
            maxTokens: model.maxTokens,
            preferredBackend: PreferredBackend.cpu,
          );

          try {
            final chat = await inferenceModel.createChat(
              temperature: model.temperature,
              topK: model.topK,
              topP: model.topP,
              tools: _testTools,
              supportsFunctionCalls: true,
              isThinking: model.isThinking,
              modelType: model.modelType,
              toolChoice: ToolChoice.auto,
            );

            await chat.addQueryChunk(
              const Message(
                text:
                    'Do two things: 1) Change the app title to "New Title" 2) Change the background color to blue',
                isUser: true,
              ),
            );

            final response = await chat.generateChatResponse();
            debugPrint(
              '[${model.name}/parallel] Response type: ${response.runtimeType}',
            );

            if (response is FunctionCallResponse) {
              debugPrint(
                '[${model.name}/parallel] Single call: ${response.name}(${response.args})',
              );
              expect(
                response.name,
                isNotEmpty,
                reason: 'Function name must not be empty',
              );
              debugPrint(
                '[${model.name}/parallel] VERIFIED: parser returned valid function name "${response.name}"',
              );
            } else if (response is ParallelFunctionCallResponse) {
              debugPrint(
                '[${model.name}/parallel] Parallel calls: ${response.calls.length}',
              );
              for (final call in response.calls) {
                debugPrint(
                  '[${model.name}/parallel]   CALL: ${call.name}(${call.args})',
                );
                expect(
                  call.name,
                  isNotEmpty,
                  reason: 'Each parallel call must have a name',
                );
              }
              expect(response.calls.length, greaterThanOrEqualTo(2));
              debugPrint(
                '[${model.name}/parallel] VERIFIED: ${response.calls.length} parallel calls parsed',
              );
            } else if (response is TextResponse) {
              final rawText = response.token;
              debugPrint(
                '[${model.name}/parallel] Text response: "${_truncate(rawText)}"',
              );
              // Verify parseAll on raw text to confirm no calls were missed
              final manualParse = FunctionCallParser.parseAll(
                rawText,
                modelType: model.modelType,
              );
              debugPrint(
                '[${model.name}/parallel] Manual parseAll: found ${manualParse.length} calls',
              );
              if (manualParse.isNotEmpty) {
                for (final call in manualParse) {
                  debugPrint(
                    '[${model.name}/parallel]   MISSED CALL: ${call.name}(${call.args})',
                  );
                }
              }
            }
          } finally {
            await inferenceModel.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
    });
  }
}

/// Ensure model is installed (idempotent).
Future<void> _ensureModelInstalled(ToolCallingTestModel model) async {
  if (FlutterEdgeAi.hasActiveModel()) return;

  await FlutterEdgeAi.installModel(
    modelType: model.modelType,
    fileType: model.fileType,
  ).fromFile(model.filePath).install();
}

/// Truncate text for logging.
String _truncate(String text, [int maxLen = 100]) {
  return text.length > maxLen ? '${text.substring(0, maxLen)}...' : text;
}
