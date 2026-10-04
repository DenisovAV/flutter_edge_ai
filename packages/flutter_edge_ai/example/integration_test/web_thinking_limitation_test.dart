/// Pins a LIMITATION: thinking mode does not reach the model on the web
/// `.litertlm` path. Written to assert the current (broken) reality, so it goes
/// RED when upstream starts honouring it — at which point the class doc in
/// `litert_lm_web_inference.dart` and the web feature matrices need updating.
///
/// Establishes two facts about the `.litertlm` web path on `@litert-lm/core`
/// 0.17.0 (still true on 0.17.1) that the docs and the code currently
/// disagree about:
///
/// Split out of web_probe_test.dart: there, this ran second, on a model whose
/// singleton session had already been used by a function-calling chat that was
/// never closed. After tools started reaching the session, this test changed
/// failure mode from "no ThinkingResponse" to "Invalid token at state 37" —
/// which could be the thinking path itself or leakage from the previous chat.
/// One test per file removes that ambiguity.
///
/// Both assertions below are written OPTIMISTICALLY on purpose: `print` output
/// is unreliable under `flutter drive`, but the text of a failed `expect` always
/// reaches the log. So a pass means the capability works, and a failure prints
/// what actually came back instead. Either outcome is the answer.
///
/// Run: chromedriver --port=4444 & ; from example/
///   flutter drive --driver=test_driver/integration_test.dart \
///     --target=integration_test/web_thinking_probe_test.dart -d web-server
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

  group('web thinking limitation (@litert-lm/core 0.17.1)', () {
    tearDownAll(_disposeModel);

    testWidgets('thinking mode does NOT reach the model on web (pins upstream gap)', (
      tester,
    ) async {
      final model = await _ensureModel();
      final chat = await model.createChat(
        isThinking: true,
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

      // Measured on @litert-lm/core 0.17.0: 36 events, every one a TextResponse.
      // Still no ThinkingResponse on 0.17.1 (2026-09-28).
      // We do send `extra_context: {thinking: true}` and
      // `filterChannelContentFromKvCache`, the same wiring native FFI uses, but
      // upstream types `extra_context` as an opaque Record and never references
      // a `thinking` key, so it does not reach the model.
      //
      // Asserted as isEmpty ON PURPOSE. If this fails, thinking started working:
      // delete this test, and update the "Limitations" doc on
      // LiteRtLmWebInferenceModel plus the web feature matrices in
      // flutter_edge_ai/README.md and website/content/docs/litertlm.md.
      expect(
        events.whereType<ThinkingResponse>(),
        isEmpty,
        reason:
            'thinking now surfaces on web (${events.length} events) — see the '
            'note above for what to update',
      );
      expect(
        events.whereType<TextResponse>(),
        isNotEmpty,
        reason: 'the turn must still produce text, not nothing',
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
