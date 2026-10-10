/// Web: the sampler values a caller passes reach `@litert-lm/core` (#572).
///
/// Until flutter_edge_ai_litertlm 1.12.0 the web engine sent `samplerParams`
/// without a `type`, so the session config stayed TYPE_UNSPECIFIED and the
/// engine replaced the whole sampler with the bundle's, or with greedy when the
/// bundle had none. Gemma 4's web bundle has none, so every request decoded
/// greedily whatever it asked for.
///
/// The check: one fresh engine answers with hot sampling, a second fresh
/// engine answers the same prompt greedily (`topK: 1`). If the hot values were
/// dropped, both decode greedily and the replies match. Each config gets its
/// own engine because LiteRT-LM keeps the sampler of an engine's first
/// conversation (google-ai-edge/LiteRT-LM#2080), so the test does not depend
/// on how the engine carries its random state between conversations.
///
/// Run with:
///   chromedriver --port=4444 &
///   cd example
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/litertlm_web_sampling_test.dart \
///     -d web-server
///
/// Everything that can fail sits inside the test body: under `flutter drive` a
/// throwing setUp is reported as "All tests passed" (AGENTS.md rule 6b).
@TestOn('chrome')
library;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

// A local copy keeps back-to-back runs off the network, e.g.
// --dart-define=WEB_MODEL_URL=http://127.0.0.1:8765/gemma-4-E2B-it-web.litertlm
const _webModelUrl = String.fromEnvironment(
  'WEB_MODEL_URL',
  defaultValue:
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm',
);

const _hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('explicit sampling values reach the web engine', (tester) async {
    await registerTestEngines();
    final installer = FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    );
    await installer
        .fromNetwork(_webModelUrl, token: _hfToken.isEmpty ? null : _hfToken)
        .install();

    Future<String> answer({
      double? temperature,
      int? topK,
      double? topP,
      int? randomSeed,
    }) async {
      final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
      try {
        final session = await model.createSession(
          temperature: temperature,
          topK: topK,
          topP: topP,
          randomSeed: randomSeed,
          maxOutputTokens: 48,
        );
        await session.addQueryChunk(
          const Message(
            text: 'Invent a name for a new fruit and describe its taste.',
            isUser: true,
          ),
        );
        final reply = await session.getResponse();
        await session.close();
        return reply;
      } finally {
        await model.close();
      }
    }

    final hot = await answer(
      temperature: 1.5,
      topK: 64,
      topP: 1.0,
      randomSeed: 7,
    );
    final greedy = await answer(topK: 1);
    // ignore: avoid_print
    print('[SAMPLING] hot: $hot');
    // ignore: avoid_print
    print('[SAMPLING] greedy: $greedy');
    expect(hot, isNotEmpty);
    expect(greedy, isNotEmpty);
    expect(
      hot,
      isNot(greedy),
      reason: 'the hot reply is the greedy one: the values never arrived',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}
