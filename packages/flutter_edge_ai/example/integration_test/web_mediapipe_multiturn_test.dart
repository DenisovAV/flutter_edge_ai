/// A multi-turn chat on the web MediaPipe `.task` path keeps the model's own
/// replies (#705).
///
/// `LlmInference.generateResponse` of `@mediapipe/tasks-genai` 0.10.29 is
/// stateless: every call builds a new native session, so the web session has to
/// send the whole conversation each turn, the model's replies included. The
/// question of turn 2 depends on the answer of turn 1; a prompt that leaves the
/// reply out cannot answer it.
///
/// One test per web `.task` of the example catalog, greedy, with the exact
/// replies of both turns in the output.
///
/// Run: chromedriver --port=4444 & ; from example/
///   flutter drive --driver=test_driver/web_mediapipe_multiturn_driver.dart \
///     --target=integration_test/web_mediapipe_multiturn_test.dart \
///     -d web-server --web-browser-flag=--enable-unsafe-webgpu
///
/// The Gemma 4 files are public. The Gemma 3 files are gated on Hugging Face:
/// download them once and serve the four files from a local directory with
/// range support, then pass its address:
///   --dart-define=WEB_TASK_BASE=http://127.0.0.1:8766
/// Without it the Gemma 4 files come from Hugging Face and the Gemma 3 tests
/// are skipped. `--dart-define=WEB_ONLY=gemma-4-E2B` runs one model.
///
/// Nothing in CI runs this file; re-run it when `@mediapipe/tasks-genai` moves
/// in `example/web/index.html`.
@TestOn('chrome')
library;

import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';

const _taskBase = String.fromEnvironment('WEB_TASK_BASE');

/// Runs only the models whose name contains this, e.g. `gemma-4-E2B`.
const _only = String.fromEnvironment('WEB_ONLY');

const _hfGemma4E2B =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.task';
const _hfGemma4E4B =
    'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it-web.task';

/// The four web `.task` files of the example catalog (`model.dart`).
class _WebTask {
  const _WebTask(this.name, this.file, this.type, {this.publicUrl});
  final String name;
  final String file;
  final ModelType type;

  /// Where the file is public; null for a gated one, which needs [_taskBase].
  final String? publicUrl;

  String? get url => _taskBase.isNotEmpty ? '$_taskBase/$file' : publicUrl;
}

const _models = [
  _WebTask(
    'gemma-4-E2B-it-web',
    'gemma-4-E2B-it-web.task',
    ModelType.gemma4,
    publicUrl: _hfGemma4E2B,
  ),
  _WebTask(
    'gemma-4-E4B-it-web',
    'gemma-4-E4B-it-web.task',
    ModelType.gemma4,
    publicUrl: _hfGemma4E4B,
  ),
  _WebTask(
    'gemma3-1b-it-int4-web',
    'gemma3-1b-it-int4-web.task',
    ModelType.gemmaIt,
  ),
  _WebTask(
    'gemma3-270m-it-q8-web',
    'gemma3-270m-it-q8-web.task',
    ModelType.gemmaIt,
  ),
];

const _question1 = 'Pick a random fruit and say only its name.';
const _question2 = 'Which fruit did you pick? Say only its name.';

// Greedy decoding can answer the fruit question of turn 2 with no history at
// all (it picks the same fruit again), so the fruit pair cannot tell a chat
// that keeps the replies from one that drops them. The number cannot be
// guessed: turn 2 is only answerable from the reply of turn 1.
const _number1 = 'Say a random 4-digit number and nothing else.';
const _number2 =
    'Add 1 to the number you just said. Say only the resulting number.';

bool _enginesRegistered = false;

/// Everything that can fail lives in a test body, never in setUp: under
/// `flutter drive` a throwing setUp is reported as "All tests passed",
/// because integration_test only writes a result from inside `runTest`
/// (AGENTS.md, Rule 6b).
Future<InferenceModel> _load(_WebTask task) async {
  if (!_enginesRegistered) {
    // Streaming (OPFS) storage: the 3 GB E4B file does not fit a blob.
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [MediaPipeEngine()],
      webStorageMode: WebStorageMode.streaming,
    );
    _enginesRegistered = true;
  }
  await FlutterEdgeAi.installModel(
    modelType: task.type,
    fileType: ModelFileType.task,
  ).fromNetwork(task.url!).install();
  return FlutterEdgeAi.getActiveModel(maxTokens: 1024);
}

Future<String> _ask(InferenceChat chat, String question) async {
  await chat.addQueryChunk(Message(text: question, isUser: true));
  final response = await chat.generateChatResponse();
  expect(response, isA<TextResponse>(), reason: '$response');
  return (response as TextResponse).token;
}

String _letters(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z]'), '');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final replies = <String, Object?>{};
  binding.reportData = replies;

  for (final task in _models) {
    testWidgets(
      '${task.name}: turn 2 is answered from the reply of turn 1',
      skip: task.url == null || !task.name.contains(_only),
      timeout: const Timeout(Duration(minutes: 20)),
      (tester) async {
        final model = await _load(task);
        final chat = await model.createChat(
          modelType: task.type,
          temperature: 0,
          topK: 1,
        );
        try {
          final reply1 = await _ask(chat, _question1);
          // ignore: avoid_print
          print('[${task.name}] turn 1: ${_quoted(reply1)}');
          replies[task.name] = {'turn1': reply1};
          expect(
            reply1.trim(),
            isNotEmpty,
            reason: 'turn 1 was empty: the model got no usable first prompt',
          );

          final reply2 = await _ask(chat, _question2);
          // ignore: avoid_print
          print('[${task.name}] turn 2: ${_quoted(reply2)}');
          replies[task.name] = {'turn1': reply1, 'turn2': reply2};
          expect(
            _letters(reply2),
            contains(_letters(reply1)),
            reason:
                'turn 2 ("$reply2") does not name the fruit of turn 1 '
                '("$reply1")',
          );

          // A second chat: the reply of turn 1 is a number the model must use.
          final numbers = await model.createChat(
            modelType: task.type,
            temperature: 0,
            topK: 1,
          );
          try {
            final n1 = await _ask(numbers, _number1);
            final n2 = await _ask(numbers, _number2);
            // ignore: avoid_print
            print('[${task.name}] number: ${_quoted(n1)} -> ${_quoted(n2)}');
            replies[task.name] = {
              'turn1': reply1,
              'turn2': reply2,
              'number1': n1,
              'number2': n2,
            };
            final first = int.tryParse(
              RegExp(r'\d{4}').firstMatch(n1)?.group(0) ?? '',
            );
            expect(first, isNotNull, reason: 'no 4-digit number in "$n1"');
            expect(
              n2,
              contains('${first! + 1}'),
              reason: 'turn 2 ("$n2") is not the number of turn 1 ("$n1") + 1',
            );
          } finally {
            await numbers.close();
          }
        } finally {
          await chat.close();
        }
      },
    );
  }

  for (final task in _models) {
    testWidgets(
      '${task.name}: a stopped reply keeps the chat usable',
      skip: task.url == null || !task.name.contains(_only),
      timeout: const Timeout(Duration(minutes: 20)),
      (tester) async {
        final model = await _load(task);
        final chat = await model.createChat(
          modelType: task.type,
          temperature: 0,
          topK: 1,
        );
        try {
          await chat.addQueryChunk(
            const Message(
              text: 'Count from 1 to 200, separated by commas.',
              isUser: true,
            ),
          );
          final seen = StringBuffer();
          final done = Completer<void>();
          final sub = chat.generateChatResponseAsync().listen(
            (r) {
              if (r is TextResponse) seen.write(r.token);
              if (seen.length > 20 && !done.isCompleted) done.complete();
            },
            onError: (Object e) {
              if (!done.isCompleted) done.completeError(e);
            },
          );
          await done.future.timeout(const Duration(minutes: 5));
          await chat.stopGeneration();
          await sub.cancel();
          // ignore: avoid_print
          print('[${task.name}] stopped after: ${_quoted(seen.toString())}');
          expect(seen.toString(), isNotEmpty);

          final after = await _ask(chat, 'Say only the word done.');
          // ignore: avoid_print
          print('[${task.name}] after stop: ${_quoted(after)}');
          replies['${task.name}#stop'] = {
            'partial': seen.toString(),
            'after': after,
          };
          expect(after.trim(), isNotEmpty);
        } finally {
          await chat.close();
        }
      },
    );
  }

  tearDownAll(FlutterEdgeAi.reset);
}

String _quoted(String s) => '"${s.replaceAll('\n', r'\n')}"';
