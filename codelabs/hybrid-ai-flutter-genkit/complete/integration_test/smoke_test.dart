import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:integration_test/integration_test.dart';
import 'package:workshop_genkit_flutter_hybrid_ai/services/ai_engine.dart';

// FTL pushes the model here via `--other-files`; if present we install from it
// (no flaky on-device download). Absent (local run) → normal HF download.
const _stagedModel =
    '/data/local/tmp/flutter_edge_ai_test/gemma3-1b-it-int4.litertlm';

// On-device smoke test for FTL / a real device.
// Run with both secrets:
//   --dart-define=HF_TOKEN=hf_xxx --dart-define=GEMINI_API_KEY=AIza...
// It downloads Gemma-3-1B on first run (the embedder is intentionally skipped
// via downloadEmbedder: false — this test exercises generation, not RAG),
// then exercises the two real model backends through AiEngine (the paths
// unit tests can't cover).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'AiEngine e2e: init downloads models, local + cloud generate non-empty',
    (tester) async {
      final engine = AiEngine();
      addTearDown(engine.dispose);

      final staged = File(_stagedModel).existsSync() ? _stagedModel : null;
      // Skip the embedder download — this smoke test exercises generation, not RAG.
      await engine.initialize(localModelPath: staged, downloadEmbedder: false);

      // The on-device backend is mandatory on a device smoke run — the model
      // is staged/downloaded and HF_TOKEN is provided, so a silently-broken
      // LiteRT-LM path must fail here, not ship green on cloud alone.
      expect(
        engine.localReady,
        isTrue,
        reason: 'on-device LiteRT-LM backend failed to initialize',
      );

      final msg = Message(
        role: Role.user,
        content: [TextPart(text: 'Reply with a short greeting.')],
      );

      final resp = await engine.ai.generate(
        model: engine.modelFor(PolicyMode.local),
        messages: [msg],
      );
      expect(
        resp.text.trim(),
        isNotEmpty,
        reason: 'on-device (Gemma-3-1B) produced empty text',
      );
      // ignore: avoid_print
      print('[smoke] LOCAL ok (chars=${resp.text.trim().length})');

      if (engine.cloudReady) {
        final cloudResp = await engine.ai.generate(
          model: engine.modelFor(PolicyMode.cloud),
          messages: [msg],
        );
        expect(
          cloudResp.text.trim(),
          isNotEmpty,
          reason: 'cloud (gemini-3.7-flash) produced empty text',
        );
        // ignore: avoid_print
        print('[smoke] CLOUD ok (chars=${cloudResp.text.trim().length})');
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
