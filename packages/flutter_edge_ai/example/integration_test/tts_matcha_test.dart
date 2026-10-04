// On-device Matcha TTS e2e — installs Matcha-TTS from HuggingFace and
// synthesizes through the public API (initialize -> installTts ->
// getActiveTts -> synthesize), byte-comparing the output against a
// committed golden PCM captured from this deterministic pipeline (fixed
// CFM seed).
//
// Run: cd packages/flutter_edge_ai/example && \
//   flutter test integration_test/tts_matcha_test.dart -d macos
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show FlutterEdgeAi, TtsModelType;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    show LiteRtTtsBackend;

const _modelUrl =
    'https://huggingface.co/litert-community/Matcha-TTS/resolve/main/';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Matcha synthesizes "Hello world." byte-identical to the golden PCM',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.matcha)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();

      try {
        final pcm = await synth.synthesize('Hello world.');

        final golden = await rootBundle.load('assets/test/tts_golden.pcm');
        final goldenBytes = golden.buffer.asUint8List(
          golden.offsetInBytes,
          golden.lengthInBytes,
        );

        final samples = Int16List.sublistView(pcm);
        var sumSquares = 0.0;
        for (final s in samples) {
          sumSquares += (s / 32768.0) * (s / 32768.0);
        }
        final rms = math.sqrt(sumSquares / samples.length);
        debugPrint(
          'TTS-MATCHA-TEST<<<pcmBytes=${pcm.length} goldenBytes=${goldenBytes.length} '
          'sampleRate=${synth.sampleRate} rms=$rms>>>',
        );

        // Secondary sanity asserts (cheap, belt-and-suspenders).
        expect(synth.sampleRate, 22050);
        expect(pcm.length ~/ 2, 19456);
        expect(
          rms,
          greaterThan(0.005),
          reason: 'RMS too close to silence: $rms',
        );

        // Strong oracle: the pipeline is deterministic (fixed CFM seed), so
        // synthesize('Hello world.') must be byte-exact to the golden.
        expect(
          pcm.length,
          goldenBytes.length,
          reason: 'PCM length diverged from golden',
        );
        expect(pcm, orderedEquals(goldenBytes));
      } finally {
        await synth.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
