// On-device: InferenceChat.generateChatResponseWithTools — the full function-
// calling loop (run tool -> feed back -> final answer), which tool_calling_test
// (call detection only) does not cover.
// Run: flutter test integration_test/generate_with_tools_test.dart -d <device> \
//   --dart-define=HUGGINGFACE_TOKEN=$HF_TOKEN
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

// .litertlm (not .task): desktop/iOS run the litertlm FFI engine; MediaPipe has
// no desktop backend. Staged device-locally (no network/token) — resolved per
// platform by stagedModelPath.
const _modelFile = 'gemma3-1b-it-int4.litertlm';
const _tools = [
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

  testWidgets(
    'generateChatResponseWithTools runs the tool then answers',
    (tester) async {
      await registerTestEngines();
      final llmPath = await stagedModelPath(_modelFile);
      expect(
        llmPath,
        isNotNull,
        reason:
            'stage $_modelFile to the app documents dir (desktop/iOS) or '
            '/data/local/tmp/flutter_gemma_test/ (Android)',
      );
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(llmPath!).install();
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.cpu,
      );
      final chat = await model.createChat(
        tools: _tools,
        supportsFunctionCalls: true,
        modelType: ModelType.gemmaIt,
        toolChoice: ToolChoice.auto,
        temperature: 1.0,
        topK: 64,
        topP: 0.95,
      );

      // Same prompt tool_calling_test uses to reliably get a show_alert call.
      await chat.addQueryChunk(
        const Message(
          text: 'Show an alert with title "Test" and message "Hello"',
          isUser: true,
        ),
      );

      final calls = <FunctionCallResponse>[];
      final out = await chat
          .generateChatResponseWithTools(
            onToolCall: (c) {
              calls.add(c);
              return {'status': 'success', 'message': 'alert shown'};
            },
          )
          .toList();

      // The loop invoked the handler (tool_calling_test proves this model calls
      // show_alert for this prompt) and then terminated on a call-free turn.
      expect(calls, isNotEmpty, reason: 'no tool was called');
      debugPrint('[gwt] tools: ${calls.map((c) => c.name).toList()}');
      debugPrint(
        '[gwt] final text: '
        '"${out.whereType<TextResponse>().map((t) => t.token).join()}"',
      );
      await model.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
