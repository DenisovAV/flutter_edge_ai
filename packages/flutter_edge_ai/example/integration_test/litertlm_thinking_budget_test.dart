// LiteRtLmEngine(thinkingTokenBudget:) on a real Gemma 4 E2B, loaded as an
// app loads it (initialize, installModel, getActiveModel), greedy:
// - with thinking on, a budget of 64 cuts the thought channel short and the
//   model still answers; without one, the same turn thinks longer;
// - a budget the turn never reaches leaves it as it was, and the decode speed
//   with and without it is printed: LiteRT-LM checks the budget on every
//   token of a send that carries one;
// - a turn with thinking off is the same with a budget and without: the
//   budget never turns thinking on;
// - a tool turn with thinking on and a budget of 64 still calls the tool and
//   answers from its result.
//
// The budget is fixed when the engine is registered, so each turn closes the
// model, resets and initializes again, as an app that changes it must.
//
// Stage gemma-4-E2B-it.litertlm in the app documents dir (desktop) or
// /data/local/tmp/flutter_gemma_test/ (Android).
// Run, one GPU workload at a time:
//   flutter test integration_test/litertlm_thinking_budget_test.dart -d macos
// CPU by default; --dart-define=BUDGET_BACKEND=gpu for the GPU backend.

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'voice_test_helpers.dart' show stagedModelPath;

const _modelFileName = 'gemma-4-E2B-it.litertlm';
const _backendName = String.fromEnvironment(
  'BUDGET_BACKEND',
  defaultValue: 'cpu',
);
final _backend = PreferredBackend.values.byName(_backendName);

// The context is maxTokens, the reply maxOutputTokens, the thinking a part of
// the reply: budget < maxOutputTokens < maxTokens.
const _maxTokens = 2048;
const _maxOutputTokens = 1536;
const _budget = 64;
// Above what the free turn thinks (about 400 tokens), below maxOutputTokens.
const _unreachedBudget = 1200;

const _question =
    'A train leaves at 09:40 and arrives at 13:05. A second train leaves at '
    '10:15 and takes 25 minutes less. When does the second train arrive? '
    'Reason carefully before you answer.';

const _multiply = Tool(
  name: 'multiply',
  description:
      'Multiply two numbers and return the exact product. Use this for any '
      'multiplication instead of working it out yourself.',
  parameters: {
    'type': 'object',
    'properties': {
      'a': {'type': 'number', 'description': 'The first number.'},
      'b': {'type': 'number', 'description': 'The second number.'},
    },
    'required': ['a', 'b'],
  },
);

typedef _Turn = ({
  String thinking,
  String answer,
  int outputTokens,
  double? tokensPerSecond,
});

/// The active model, built by an engine with [budget].
Future<InferenceModel> _activeModel(int? budget) async {
  final path = await stagedModelPath(_modelFileName);
  expect(
    path,
    isNotNull,
    reason:
        'stage $_modelFileName in the app documents dir (desktop) or in '
        '/data/local/tmp/flutter_gemma_test/ (Android)',
  );
  FlutterEdgeAi.reset();
  await FlutterEdgeAi.initialize(
    inferenceEngines: [LiteRtLmEngine(thinkingTokenBudget: budget)],
  );
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  ).fromFile(path!).install();
  return FlutterEdgeAi.getActiveModel(
    maxTokens: _maxTokens,
    preferredBackend: _backend,
  );
}

Future<_Turn> _turn(
  WidgetTester tester,
  int? budget, {
  bool enableThinking = true,
}) async {
  final model = await _activeModel(budget);
  final thinking = StringBuffer();
  final answer = StringBuffer();
  try {
    final chat = await model.createChat(
      topK: 1,
      enableThinking: enableThinking,
      maxOutputTokens: _maxOutputTokens,
      modelType: ModelType.gemma4,
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
    final metrics = chat.session.getSessionMetrics();
    final turn = (
      thinking: thinking.toString(),
      answer: answer.toString(),
      outputTokens: metrics.outputTokens,
      tokensPerSecond: metrics.tokensPerSecond,
    );
    // ignore: avoid_print
    print(
      '[thinking budget] $_backendName, budget ${budget ?? 'none'}'
      '${enableThinking ? '' : ', thinking off'}: '
      'thinking ${turn.thinking.length} chars, answer ${turn.answer.length} '
      'chars, ${turn.outputTokens} output tokens, decode '
      '${turn.tokensPerSecond?.toStringAsFixed(1)} tok/s',
    );
    return turn;
  } finally {
    await model.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a thinking budget of $_budget cuts the thinking short and the '
      'model still answers ($_backendName)', (tester) async {
    final free = await _turn(tester, null);
    final capped = await _turn(tester, _budget);
    // ignore: avoid_print
    print('[thinking budget] capped answer: ${capped.answer.trim()}');

    // A token is a few characters: 64 tokens stay well under 600, and the
    // free turn must think past that or the bound proves nothing.
    expect(free.thinking.length, greaterThan(600));
    expect(capped.thinking.length, lessThan(600));
    // Cut short, not switched off or rewritten: greedy decoding thinks the
    // same tokens until the budget ends the channel, and fewer tokens are
    // decoded, not only fewer shown.
    expect(capped.thinking.trim(), isNotEmpty);
    expect(free.thinking.startsWith(capped.thinking.trimRight()), isTrue);
    expect(capped.outputTokens, lessThan(free.outputTokens));
    expect(capped.answer.trim(), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('a budget the turn never reaches changes nothing; decode speed '
      'with and without it ($_backendName)', (tester) async {
    final runs = <int?, List<_Turn>>{null: [], _unreachedBudget: []};
    for (var i = 0; i < 2; i++) {
      for (final budget in runs.keys) {
        runs[budget]!.add(await _turn(tester, budget));
      }
    }
    final free = runs[null]!.first;
    // Fewer tokens in the whole reply than the budget, so the budget was
    // never reached.
    expect(free.outputTokens, lessThan(_unreachedBudget));
    for (final turn in [...runs[null]!, ...runs[_unreachedBudget]!]) {
      expect(turn.thinking, free.thinking);
      expect(turn.answer, free.answer);
    }
    String speeds(int? budget) => runs[budget]!
        .map((t) => t.tokensPerSecond?.toStringAsFixed(1))
        .join(', ');
    // ignore: avoid_print
    print(
      '[thinking budget] $_backendName decode tok/s: no budget '
      '${speeds(null)}; budget $_unreachedBudget (not reached) '
      '${speeds(_unreachedBudget)}',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('a turn with thinking off is the same with a budget of $_budget '
      'and without ($_backendName)', (tester) async {
    final free = await _turn(tester, null, enableThinking: false);
    final budgeted = await _turn(tester, _budget, enableThinking: false);

    expect(free.thinking, isEmpty);
    expect(budgeted.thinking, isEmpty);
    expect(budgeted.answer, free.answer);
    expect(free.answer.trim(), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('a tool turn with thinking on and a budget of $_budget calls the '
      'tool and answers from its result ($_backendName)', (tester) async {
    final model = await _activeModel(_budget);
    try {
      final chat = await model.createChat(
        topK: 1,
        tools: const [_multiply],
        supportsFunctionCalls: true,
        enableThinking: true,
        maxOutputTokens: _maxOutputTokens,
        modelType: ModelType.gemma4,
      );
      await chat.addQueryChunk(
        const Message(
          text: 'What is 1234 times 5678? Use your tools.',
          isUser: true,
        ),
      );
      final calls = <FunctionCallResponse>[];
      final thinking = <int>[0];
      final text = StringBuffer();
      var capped = false;
      await tester.runAsync(() async {
        await for (final r in chat.generateChatResponseWithTools(
          onToolCall: (call) async {
            calls.add(call);
            thinking.add(0);
            return {'result': 7006652};
          },
          maxToolTurns: 4,
          onMaxToolTurns: () => capped = true,
        )) {
          switch (r) {
            case ThinkingResponse(:final content):
              thinking.last += content.length;
            case TextResponse(:final token):
              text.write(token);
            default:
          }
        }
      });
      // ignore: avoid_print
      print(
        '[thinking budget] $_backendName tools, budget $_budget: calls '
        '${calls.map((c) => '${c.name}(${c.args})').join(', ')}; thinking '
        'chars per generation $thinking; answer: ${text.toString().trim()}',
      );

      expect(capped, isFalse);
      // The first generation thinks, within the budget. Gemma 4 E2B does not
      // think again after the tool result, so a later generation's own budget
      // is not shown here.
      expect(thinking.first, inInclusiveRange(1, 599));
      expect(calls, hasLength(1));
      expect(calls.single.name, 'multiply');
      expect(calls.single.args, {'a': 1234, 'b': 5678});
      expect(text.toString().replaceAll(',', ''), contains('7006652'));
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
