// On-device (macOS/desktop): the FULL public path for Inflect TTS —
// install (cross-repo: 2 tflites from the Inflect repo + 4 G2P files from the
// Matcha repo, routed by TtsModelType.inflect.fetchLocationFor) ->
// getActiveTts ->
// synthesize (through the background worker's inflectVits arm) -> non-silent
// 24 kHz PCM. Public repos, no token.
//
// Run: cd packages/flutter_edge_ai/example && \
//   flutter test integration_test/inflect_public_test.dart -d macos
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Inflect public path: install (2-repo) -> getActiveTts -> synthesize',
    (tester) async {
      await FlutterEdgeAi.initialize(
        ttsBackends: const [LiteRtTtsBackend()],
        inferenceEngines: const [LiteRtLmEngine()],
      );

      // Optional HF token via --dart-define=HF_TOKEN=... — the repo is public,
      // so anonymous is the default; a token only matters if HF ever gates it.
      const hfToken = String.fromEnvironment('HF_TOKEN');
      await FlutterEdgeAi.installTts()
          .fromNetwork(
            'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/',
            token: hfToken.isEmpty ? null : hfToken,
          )
          .ofType(TtsModelType.inflect)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();
      addTearDown(synth.close);

      final pcm = await synth.synthesize(
        'Hello there, this is flutter gemma speaking.',
      );

      expect(
        pcm.length,
        greaterThan(24000),
        reason: 'expected > ~0.5 s of 16-bit 24 kHz audio',
      );
      final bd = ByteData.sublistView(pcm);
      var nonZero = 0;
      final n = pcm.length ~/ 2;
      for (var i = 0; i < n; i++) {
        if (bd.getInt16(i * 2, Endian.little) != 0) nonZero++;
      }
      debugPrint('[inflect-public] $n samples ($nonZero non-zero)');
      expect(nonZero, greaterThan(n ~/ 4), reason: 'reply audio is silence');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
