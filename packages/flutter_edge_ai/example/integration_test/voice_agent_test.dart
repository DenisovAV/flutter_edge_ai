// On-device: voice loop backed by the full agent. Fixed transcript
// -> AgentSession (calculate-hash skill) -> Inflect TTS. Asserts the skill's
// deterministic SHA-1 surfaces and a spoken reply is produced.
//
// JS skills need a real webview host (agent_with_model_test.dart's
// _skipJsNoHarnessWebview); this test mirrors that skip on Linux/Windows.
//
// Run: flutter test integration_test/voice_agent_test.dart -d <device> \
//   --dart-define=HUGGINGFACE_TOKEN=$HF_TOKEN
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_edge_ai_example/tools/agent_voice_responder.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'voice_test_helpers.dart';

const _llmFileName = 'gemma-4-E2B-it.litertlm';
const _ttsUrl =
    'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/';
const _sha1OfHello = 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d';

/// JS skills (calculate-hash) require a real webview host — same mechanism
/// probe as agent_with_model_test.dart's `_skipJsNoHarnessWebview`.
bool _skipJsNoHarnessWebview() {
  if (Platform.isLinux) {
    debugPrint('[voice_agent] SKIP on Linux: JS skills require a webview');
    return true;
  }
  if (Platform.isWindows) {
    debugPrint(
      '[voice_agent] SKIP on Windows: HeadlessInAppWebView (WebView2) crashes '
      'under flutter test (needs an HWND); mechanism probe-proven',
    );
    return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'voice + agent: fixed transcript -> skill -> spoken reply',
    (tester) async {
      if (_skipJsNoHarnessWebview()) return;

      await FlutterEdgeAi.initialize(
        ttsBackends: const [LiteRtTtsBackend()],
        inferenceEngines: const [LiteRtLmEngine()],
      );
      final llmPath = await stagedModelPath(_llmFileName);
      expect(
        llmPath,
        isNotNull,
        reason:
            'stage $_llmFileName to the app documents dir (desktop/iOS) or '
            '/data/local/tmp/flutter_gemma_test/ (Android)',
      );
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(llmPath!).install();
      await FlutterEdgeAi.installTts()
          .fromNetwork(_ttsUrl)
          .ofType(TtsModelType.inflect)
          .install();

      // Agent with the bundled calculate-hash skill (deterministic output) —
      // same wiring as agent_with_model_test.dart's `_session`.
      final assetSource = AssetSkillSource();
      final skills = await assetSource.load();
      final registry = SkillRegistry()..addAll(skills, selected: true);
      // CPU: the voice path loads Inflect TTS (Metal) alongside the LLM; a
      // concurrent Metal GPU load is flaky on desktop (agent_with_model_test can
      // use GPU because it has no TTS). This gate proves the agent->voice loop,
      // not GPU perf — pin CPU for determinism.
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.cpu,
      );
      final agent = await AgentSession.fromModel(
        model,
        registry: registry,
        executors: [
          TextSkillExecutor(),
          JsSkillExecutor(sourceFor: assetSource.jsSkillSourceFor),
        ],
      );
      final synth = await FlutterEdgeAi.getActiveTts();

      final session = VoiceSession.custom(
        recognizer: FixedTranscriptRecognizer('Calculate the hash of hello'),
        responder: agentVoiceResponder(agent),
        synthesizer: synth,
      );

      final events = await session.runTurn(Uint8List(0)).toList();

      final reply = events
          .whereType<VoiceReplyTextEvent>()
          .map((e) => e.chunk)
          .join();
      expect(
        reply.toLowerCase(),
        contains(_sha1OfHello),
        reason: "the skill's SHA-1 did not reach the spoken reply",
      );
      expect(events.whereType<VoiceReplyAudioEvent>(), isNotEmpty);

      await agent.close();
      await model.close();
      await synth.close();
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
