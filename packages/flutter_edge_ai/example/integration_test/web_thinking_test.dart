/// Thinking reaches the model on the web `.litertlm` path.
///
/// This used to pin the opposite: the web path sent `extra_context:
/// {thinking: true}`, a key no chat template reads, so Gemma 4 never thought on
/// web and the gap was blamed on upstream. Upstream's own web chat app sends
/// `enable_thinking`, and so do we now (`thinkingContext`). Measured on
/// `@litert-lm/core` 0.17.1 in Chrome: with the old key this test's
/// `ThinkingResponse` list was empty; with `enable_thinking` it is not.
///
/// Run: chromedriver --port=4444 & ; from example/
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/web_thinking_test.dart -d web-server
@TestOn('chrome')
library;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _webModelUrl =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm';

const _hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

InferenceModel? _model;
bool _enginesRegistered = false;

/// Everything that can fail lives in a test body, never in setUp: under
/// `flutter drive` a throwing setUp is reported as "All tests passed", because
/// integration_test only writes a result from inside `runTest`.
Future<InferenceModel> _ensureModel() async {
  if (!_enginesRegistered) {
    await registerTestEngines();
    _enginesRegistered = true;
  }
  if (_model != null) return _model!;
  final installer = FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  );
  await installer
      .fromNetwork(_webModelUrl, token: _hfToken.isEmpty ? null : _hfToken)
      .install();
  return _model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
}

Future<void> _disposeModel() async {
  await _model?.close();
  _model = null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('web thinking (@litert-lm/core 0.17.1)', () {
    tearDownAll(_disposeModel);

    testWidgets('enableThinking reaches the model on web', (tester) async {
      final model = await _ensureModel();
      final chat = await model.createChat(
        enableThinking: true,
        modelType: ModelType.gemma4,
      );
      await chat.addQueryChunk(
        const Message(
          text:
              'A farmer has 17 sheep. All but 9 run away. How many remain? '
              'Think it through.',
          isUser: true,
        ),
      );

      final events = <ModelResponse>[];
      await for (final e in chat.generateChatResponseAsync()) {
        events.add(e);
      }
      final thinking = events.whereType<ThinkingResponse>().length;
      final text = events.whereType<TextResponse>().length;

      // `print` is unreliable under `flutter drive`; a failed expect's reason
      // always reaches the log, so the counts ride in the reasons.
      expect(
        thinking,
        greaterThan(0),
        reason: 'no reasoning on web: $text text events, $thinking thinking',
      );
      expect(
        text,
        greaterThan(0),
        reason: 'reasoning but no answer: $thinking thinking events',
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
