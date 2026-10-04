// On-device Qwen3-TTS e2e — installs Qwen3-TTS from HuggingFace through the
// REAL public flow (initialize -> installTts -> getActiveTts -> synthesize),
// exercising the plain-basename manifest -> getModelFilePaths ->
// Qwen3TtsCore.load consistency ON DEVICE (the artifact-gated unit tests
// build their own artifactPaths by directory scan, so they never touch the
// install path itself).
//
// Unlike `tts_matcha_test.dart` (byte-exact against a committed golden,
// fixed CFM seed), this test asserts PLAUSIBILITY only: the runtime uses the
// default int4 talker with `doSample: true`, so exact bytes are not
// reproducible across runs. The byte-exact / corr~=1.0 oracle for the shared
// AR pipeline lives in the fp32-greedy unit test (`qwen3_synthesize_test.dart`,
// artifact-gated, not a device test).
//
// Also asserts language selection actually changes the output end to end:
// synthesizing the same text with `language: 'german'` after closing the
// `'english'` synthesizer (required by the fail-loud language-cache guard —
// see Task 5.4) must NOT produce byte-identical audio to the english pass.
//
// The full 9-file bundle is ~1.9 GB; this test can take tens of minutes on a
// slow connection. Run: cd packages/flutter_edge_ai/example && \
//   flutter test integration_test/qwen3_tts_test.dart -d macos
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show FlutterEdgeAi, TtsModelType;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    show LiteRtTtsBackend;

const _modelUrl =
    'https://huggingface.co/litert-community/Qwen3-TTS-12Hz-0.6B-Base/resolve/main/';
const _text = 'Hello from on device text to speech.';

double _rms(Uint8List pcm) {
  final samples = Int16List.sublistView(pcm);
  if (samples.isEmpty) return 0;
  var sumSquares = 0.0;
  for (final s in samples) {
    final n = s / 32768.0;
    sumSquares += n * n;
  }
  return math.sqrt(sumSquares / samples.length);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Qwen3-TTS installs from HF, synthesizes plausible english audio, and '
    'german differs from english',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.qwen3)
          .install();

      final englishSynth = await FlutterEdgeAi.getActiveTts(language: 'english');
      Uint8List englishPcm;
      try {
        englishPcm = await englishSynth.synthesize(_text);

        expect(englishPcm, isNotEmpty, reason: 'english PCM was empty');
        expect(englishSynth.sampleRate, 24000);

        final durationSeconds = englishPcm.length / 2 / englishSynth.sampleRate;
        final rms = _rms(englishPcm);

        debugPrint(
          'QWEN3-TTS-DEVICE-GATE<<<lang=english pcmBytes=${englishPcm.length} '
          'durationSeconds=${durationSeconds.toStringAsFixed(4)} '
          'rms=${rms.toStringAsFixed(4)}>>>',
        );

        // Plausibility oracle (int4 + doSample:true is not byte-reproducible
        // across runs/backends): non-silent, non-clipped-garbage, and a
        // ~7-word sentence should take at least ~1s of audio.
        expect(
          durationSeconds,
          greaterThanOrEqualTo(1.0),
          reason: 'Synthesized audio implausibly short: ${durationSeconds}s',
        );
        expect(
          rms,
          inInclusiveRange(0.005, 0.5),
          reason: 'RMS out of the plausible speech band: $rms',
        );
      } finally {
        // REQUIRED before requesting a different language on the same
        // active model — the language-cache guard (Task 5.4) throws
        // StateError otherwise instead of silently reusing the english
        // synthesizer for a german request.
        await englishSynth.close();
      }

      final germanSynth = await FlutterEdgeAi.getActiveTts(language: 'german');
      try {
        final germanPcm = await germanSynth.synthesize(_text);

        expect(germanPcm, isNotEmpty, reason: 'german PCM was empty');
        expect(germanSynth.sampleRate, 24000);

        final durationSeconds = germanPcm.length / 2 / germanSynth.sampleRate;
        final rms = _rms(germanPcm);

        debugPrint(
          'QWEN3-TTS-DEVICE-GATE<<<lang=german pcmBytes=${germanPcm.length} '
          'durationSeconds=${durationSeconds.toStringAsFixed(4)} '
          'rms=${rms.toStringAsFixed(4)}>>>',
        );

        expect(
          durationSeconds,
          greaterThanOrEqualTo(1.0),
          reason: 'Synthesized audio implausibly short: ${durationSeconds}s',
        );
        expect(
          rms,
          inInclusiveRange(0.005, 0.5),
          reason: 'RMS out of the plausible speech band: $rms',
        );

        // Language selection actually changes the model's output, end to
        // end through the public API: german must not equal english either
        // in length or in bytes (a byte match at equal length would mean
        // the language control token silently had no effect).
        final identical =
            germanPcm.length == englishPcm.length &&
            _bytesEqual(germanPcm, englishPcm);
        expect(
          identical,
          isFalse,
          reason:
              'german synthesis produced byte-identical audio to english '
              '(pcmBytes=${germanPcm.length} vs ${englishPcm.length}) — '
              'language selection had no effect',
        );
      } finally {
        await germanSynth.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 90)),
  );
}
