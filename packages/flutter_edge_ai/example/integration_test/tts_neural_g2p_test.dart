// On-device neural G2P (dp_g2p graph) e2e — installs the Matcha-TTS bundle
// and drives `TtsCore.neuralG2p` directly (not the public synthesize() API)
// to verify the 4th LiteRT graph loads and produces IPA phonemes for words
// that need the neural OOV fallback.
//
// NOTE: this test runs ON-DEVICE and its actual run is DEFERRED to Task 12
// (this machine's disk is tight; Task 7 only wrote the code + this file).
//
// This reaches into `flutter_edge_ai_speech`'s `lib/src/...` (TtsCore,
// TtsModelProfile) rather than the public barrel — TtsCore.neuralG2p is not
// (yet) exposed on the public SpeechSynthesizer surface, and this test's
// purpose is to white-box-verify the graph load + decode, mirroring how
// `tts_core_test.dart` (package-internal unit tests) already imports
// `package:flutter_edge_ai_speech/src/litert/tts_core.dart`.
//
// Run: cd packages/flutter_edge_ai/example && \
//   flutter test integration_test/tts_neural_g2p_test.dart -d macos
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show FlutterEdgeAi, FlutterEdgeAiPlugin, TtsModelSpec, TtsModelType;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    show LiteRtTtsBackend;
import 'package:flutter_edge_ai_speech/src/litert/tts_core.dart' show TtsCore;
import 'package:flutter_edge_ai_speech/src/model/tts_model_profile.dart'
    show TtsModelProfile;

const _modelUrl =
    'https://huggingface.co/litert-community/Matcha-TTS/resolve/main/';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'neuralG2p produces IPA phonemes via the dp_g2p graph',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.matcha)
          .install();

      final manager = FlutterEdgeAiPlugin.instance.modelManager;
      final activeModel = manager.activeTtsModel;
      if (activeModel is! TtsModelSpec) {
        fail('No active TTS model after install()');
      }
      final artifactPaths = await manager.getModelFilePaths(activeModel);
      if (artifactPaths == null || artifactPaths.isEmpty) {
        fail('Active TTS model files not found on disk');
      }

      final core = await TtsCore.load(
        profile: TtsModelProfile.forType(activeModel.ttsModelType),
        artifactPaths: artifactPaths,
      );

      try {
        expect(core.neuralG2p('world'), 'wˈɜːld');

        final chomsky = core.neuralG2p('chomsky');
        expect(chomsky, isNotEmpty);
        expect(chomsky.contains('ˈ'), isTrue);
      } finally {
        core.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
