// Portable cross-platform on-device TTS e2e (Matcha). Runs the full public
// flow (initialize -> installTts -> getActiveTts -> synthesize) and asserts a
// TOLERANCE oracle (non-silent + duration/sample-count/RMS within ±tolerance
// of the macOS-CPU golden), NOT a byte-exact match: a different arch/libm/
// accelerator can legitimately differ in the low float bits. Byte-identity to
// the committed golden is reported informationally. This is the portable
// counterpart to the byte-exact `tts_matcha_test.dart` (which is macOS-CPU
// specific) — it is meant to pass on every native platform.
//
// Run: cd packages/flutter_edge_ai/example && \
//   flutter test integration_test/tts_smoke_test.dart -d <device>
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

// Golden reference values (captured on macOS CPU).
const _goldenSamples = 19456;
const _goldenDurationSeconds = 0.882;
const _goldenRms = 0.0781;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'cross-platform smoke: install -> getActiveTts -> synthesize (tolerance oracle)',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.matcha)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();

      try {
        final pcm = await synth.synthesize('Hello world.');

        expect(pcm.isNotEmpty, isTrue, reason: 'PCM output was empty');
        expect(synth.sampleRate, 22050);

        final samples = Int16List.sublistView(pcm);
        final sampleCount = samples.length;
        final durationSeconds = sampleCount / synth.sampleRate;

        var sumSquares = 0.0;
        for (final s in samples) {
          sumSquares += (s / 32768.0) * (s / 32768.0);
        }
        final rms = math.sqrt(sumSquares / sampleCount);

        // Informational: compare against the committed macOS-CPU golden.
        final golden = await rootBundle.load('assets/test/tts_golden.pcm');
        final goldenBytes = golden.buffer.asUint8List(
          golden.offsetInBytes,
          golden.lengthInBytes,
        );
        final byteIdentical =
            pcm.length == goldenBytes.length && _bytesEqual(pcm, goldenBytes);

        double? rmsError;
        if (!byteIdentical && pcm.length == goldenBytes.length) {
          final goldenSamplesView = Int16List.sublistView(goldenBytes);
          var errSumSquares = 0.0;
          final n = math.min(samples.length, goldenSamplesView.length);
          for (var i = 0; i < n; i++) {
            final diff = (samples[i] - goldenSamplesView[i]) / 32768.0;
            errSumSquares += diff * diff;
          }
          rmsError = math.sqrt(errSumSquares / n);
        }

        debugPrint(
          'TTS-XPLAT-SMOKE<<<pcmBytes=${pcm.length} samples=$sampleCount '
          'durationSeconds=${durationSeconds.toStringAsFixed(4)} rms=${rms.toStringAsFixed(4)} '
          'byteIdentical=$byteIdentical rmsErrorVsGolden=${rmsError?.toStringAsFixed(6) ?? "n/a (length mismatch)"} '
          'goldenBytes=${goldenBytes.length}>>>',
        );

        // Tolerance oracle.
        final sampleTolerance = _goldenSamples * 0.05;
        expect(
          sampleCount,
          closeTo(_goldenSamples, sampleTolerance),
          reason:
              'Sample count out of ±5% tolerance vs golden ($_goldenSamples)',
        );
        expect(
          durationSeconds,
          closeTo(_goldenDurationSeconds, _goldenDurationSeconds * 0.05),
          reason:
              'Duration out of ±5% tolerance vs golden (${_goldenDurationSeconds}s)',
        );
        expect(
          rms,
          greaterThan(0.02),
          reason: 'RMS too close to silence: $rms',
        );
        expect(
          rms,
          closeTo(_goldenRms, 0.02),
          reason: 'RMS out of ±0.02 tolerance vs golden ($_goldenRms)',
        );
      } finally {
        await synth.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
