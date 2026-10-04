// End-to-end check of a tool-calling turn on a real device or desktop.
//
// Downloads Gemma 4 E2B (2.59 GB, ungated — no Hugging Face token), opens one
// chat with all four declarations and thinking on, and asks a question whose
// answer the model cannot produce on its own. The claim under test is the
// codelab's thesis: the model asks, the app answers, and the number in the
// reply is the one YOUR function computed.
//
// Not part of CI (needs a device and a 2.59 GB download):
//   flutter test integration_test/function_calling_test.dart -d <device-id>
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:edge_ai_quickstart/model.dart';
import 'package:edge_ai_quickstart/tools.dart';

/// Downloads the model if it is not here, and makes it the active one either
/// way. `install()` is idempotent, so a second run costs nothing.
Future<void> _install(ModelChoice model) async {
  var last = -1;
  await model
      .locate(
        FlutterEdgeAi.installModel(
          modelType: model.modelType,
          fileType: ModelFileType.litertlm,
        ),
      )
      .withProgress((p) {
        if (p >= last + 25) {
          last = p;
          debugPrint('[function-calling] download $p%');
        }
      })
      .install();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the model asks, the app answers, the number is the app\'s', (
    tester,
  ) async {
    await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);

    const model = Models.gemma4;
    await _install(model);
    expect(await FlutterEdgeAi.isModelInstalled(model.fileName), isTrue);

    // Nothing tool-related on this call: tools belong to the session.
    final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
    final chat = await inference.createChat(
      modelType: model.modelType,
      tools: toolbox,
      supportsFunctionCalls: true,
      toolChoice: ToolChoice.auto,
      isThinking: model.supportsThinking,
      maxOutputTokens: 512,
    );

    // A cap below 1 would answer the staged turn with nothing and close the
    // stream — indistinguishable from a model with nothing to say. The SDK
    // refuses instead, and it refuses before it generates, so this costs no
    // tokens and disturbs no history.
    await expectLater(
      chat
          .generateChatResponseWithTools(
            onToolCall: (_) async => const {},
            maxToolTurns: 0,
          )
          .toList(),
      throwsA(isA<RangeError>()),
    );

    await chat.addQueryChunk(
      Message.text(
        text: 'What is 1234 times 5678? Use your tools.',
        isUser: true,
      ),
    );

    final calls = <FunctionCallResponse>[];
    final results = <Map<String, dynamic>>[];
    final reply = StringBuffer();
    final thought = StringBuffer();

    await for (final chunk in chat.generateChatResponseWithTools(
      onToolCall: (call) async {
        calls.add(call);
        final result = runTool(call);
        results.add(result);
        debugPrint('[function-calling] ${call.name}(${call.args}) -> $result');
        return result;
      },
      maxToolTurns: 6,
    )) {
      switch (chunk) {
        case TextResponse(:final token):
          reply.write(token);
        case ThinkingResponse(:final content):
          thought.write(content);
        case FunctionCallResponse() || ParallelFunctionCallResponse():
          fail('the loop must consume calls itself, not yield them');
      }
    }

    debugPrint('[function-calling] thinking: ${thought.toString().trim()}');
    debugPrint('[function-calling] reply: ${reply.toString().trim()}');

    // The loop ran at least one round, and it ran the tool the question needs.
    expect(calls, isNotEmpty, reason: 'the model never asked for a tool');
    final multiplied = calls.indexWhere((c) => c.name == 'multiply');
    expect(multiplied, isNot(-1), reason: 'multiply was never called');

    // Ground truth, taken from the call the model actually made rather than
    // from what it was asked: `isNotEmpty` on the reply would not tell a model
    // that used the tool from one that invented a plausible number and ignored
    // it. Whatever arguments it chose, the product in the reply must be the
    // one THIS app computed for them.
    final product = results[multiplied]['result'];
    expect(product, isNotNull, reason: 'multiply returned an error map');
    // Models write large numbers with separators; the digits are the claim.
    final digits = reply.toString().replaceAll(RegExp(r'[,\s_]'), '');
    expect(digits, contains('$product'));

    await inference.close();
  }, timeout: const Timeout(Duration(minutes: 60)));

  // No model, no device: the app's half of the loop is plain Dart and can be
  // checked without any of it.
  test('a name the app never declared is answered, not thrown', () {
    final answer = runTool(
      const FunctionCallResponse(name: 'launch_rocket', args: {}),
    );
    expect(answer['error'], contains('launch_rocket'));
  });

  test('multiply is exact where a small model is not', () {
    expect(runMultiply({'a': '1234', 'b': '5678'}), {'result': 7006652});
  });
}
