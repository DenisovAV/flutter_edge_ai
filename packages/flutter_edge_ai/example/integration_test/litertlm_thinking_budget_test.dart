// LiteRtLmEngine(thinkingTokenBudget:) on a real Gemma 4 E2B, CPU and GPU:
// with thinking on, a budget must cut the thought channel short and the model
// must still answer; without one, the same greedy turn thinks longer.
//
// Run, one GPU workload at a time:
//   flutter test integration_test/litertlm_thinking_budget_test.dart -d macos
// Model: gemma-4-E2B-it.litertlm in
//   ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/

import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _modelFileName = 'gemma-4-E2B-it.litertlm';
const _budget = 64;
const _question =
    'A train leaves at 09:40 and arrives at 13:05. A second train leaves at '
    '10:15 and takes 25 minutes less. When does the second train arrive? '
    'Reason carefully before you answer.';

typedef _Turn = ({String thinking, String answer});

Future<_Turn> _turn(
  WidgetTester tester,
  String path,
  PreferredBackend backend,
  int? budget,
) async {
  final model = await LiteRtLmEngine(thinkingTokenBudget: budget).createModel(
    InferenceModelSpec(
      name: 'gemma4-e2b',
      modelSource: FileSource(path),
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ),
    RuntimeConfig(maxTokens: 2048, modelPath: path, preferredBackend: backend),
  );
  final thinking = StringBuffer();
  final answer = StringBuffer();
  try {
    final chat = await model.createChat(
      topK: 1,
      enableThinking: true,
      maxOutputTokens: 1536,
      modelType: ModelType.gemmaIt,
    );
    await chat.addQuery(const Message(text: _question, isUser: true));
    await tester.runAsync(() async {
      await for (final r in chat.generateChatResponseAsync()) {
        switch (r) {
          case ThinkingResponse(:final content):
            thinking.write(content);
          case TextResponse(:final token):
            answer.write(token);
          default:
        }
      }
    });
  } finally {
    await model.close();
  }
  return (thinking: thinking.toString(), answer: answer.toString());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final backend in [PreferredBackend.cpu, PreferredBackend.gpu]) {
    testWidgets('a thinking budget of $_budget cuts the thinking short and the '
        'model still answers (${backend.name})', (tester) async {
      final path = '${Platform.environment['HOME']}/Documents/$_modelFileName';
      expect(File(path).existsSync(), isTrue, reason: 'stage $path');
      await registerTestEngines();

      final free = await _turn(tester, path, backend, null);
      final capped = await _turn(tester, path, backend, _budget);
      // ignore: avoid_print
      print(
        '[thinking budget] ${backend.name}: no budget ${free.thinking.length} '
        'thinking chars, answer ${free.answer.length}; budget $_budget '
        '${capped.thinking.length} thinking chars, answer '
        '${capped.answer.length}\n'
        '[thinking budget] capped answer: ${capped.answer.trim()}',
      );

      expect(free.thinking, isNotEmpty, reason: 'the free turn must think');
      expect(capped.answer.trim(), isNotEmpty);
      // A token is a few characters; 64 tokens stay well under 600.
      expect(capped.thinking.length, lessThan(600));
      expect(capped.thinking.length, lessThan(free.thinking.length));
    });
  }
}
