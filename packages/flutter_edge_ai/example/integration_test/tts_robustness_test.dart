// On-device robustness gate (Task 12) — run by the controller:
//   flutter test integration_test/tts_robustness_test.dart -d <device>
//
// Exercises the robust TTS text frontend (punctuation-as-symbols,
// numbers/acronyms, neural OOV G2P, clause chunking) end-to-end through the
// public API (initialize -> installTts -> getActiveTts -> synthesize),
// asserting each case completes without throwing and produces non-silent
// PCM. This is a TOLERANCE/behavioral gate, not a byte-exact oracle (that is
// `tts_matcha_test.dart`'s job on the clean "Hello world." path).
//
// NOTE: the >MAX_MEL single-clause overflow case is covered by a Task-3 unit
// test (deterministic input length) and is intentionally NOT duplicated here
// — reliably driving text past the mel-frame ceiling via natural text is
// flaky by construction.
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
    'https://huggingface.co/litert-community/Matcha-TTS/resolve/main/';

double _rms(Uint8List pcm) {
  final samples = Int16List.sublistView(pcm);
  var sumSquares = 0.0;
  for (final s in samples) {
    sumSquares += (s / 32768.0) * (s / 32768.0);
  }
  return math.sqrt(sumSquares / samples.length);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'punctuation: "Sure, I can help with that." synthesizes without throwing (non-silent)',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.matcha)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();

      try {
        final pcm = await synth.synthesize('Sure, I can help with that.');
        final rms = _rms(pcm);

        debugPrint(
          'TTS-ROBUST<<<case=punctuation bytes=${pcm.length} rms=${rms.toStringAsFixed(4)}>>>',
        );

        expect(pcm.isNotEmpty, isTrue, reason: 'PCM output was empty');
        expect(
          rms,
          greaterThan(0.02),
          reason: 'RMS too close to silence: $rms',
        );
      } finally {
        await synth.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'number: "Meet in 2023." synthesizes without throwing (non-silent, verifies number normalization)',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.matcha)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();

      try {
        final pcm = await synth.synthesize('Meet in 2023.');
        final rms = _rms(pcm);

        debugPrint(
          'TTS-ROBUST<<<case=number bytes=${pcm.length} rms=${rms.toStringAsFixed(4)}>>>',
        );

        expect(pcm.isNotEmpty, isTrue, reason: 'PCM output was empty');
        expect(
          rms,
          greaterThan(0.02),
          reason: 'RMS too close to silence: $rms',
        );
      } finally {
        await synth.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'OOV via neural: "Chomsky syntax." synthesizes without throwing (non-silent, routes through dp_g2p)',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.matcha)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();

      try {
        final pcm = await synth.synthesize('Chomsky syntax.');
        final rms = _rms(pcm);

        debugPrint(
          'TTS-ROBUST<<<case=oov_neural bytes=${pcm.length} rms=${rms.toStringAsFixed(4)}>>>',
        );

        expect(pcm.isNotEmpty, isTrue, reason: 'PCM output was empty');
        expect(
          rms,
          greaterThan(0.02),
          reason: 'RMS too close to silence: $rms',
        );
      } finally {
        await synth.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'chunking: "One. Two. Three." (3 clauses) synthesizes without throwing and is longer than a one-clause clip',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.matcha)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();

      try {
        // Baseline: a single clause, for a loose "multi-clause is longer"
        // comparison (chunked clauses are synthesized independently and
        // their audio concatenated, so 3 clauses should be at least as long
        // as 1).
        final baselinePcm = await synth.synthesize('One.');
        final baselineSamples = baselinePcm.length ~/ 2;

        final pcm = await synth.synthesize('One. Two. Three.');
        final rms = _rms(pcm);
        final sampleCount = pcm.length ~/ 2;

        debugPrint(
          'TTS-ROBUST<<<case=chunking bytes=${pcm.length} rms=${rms.toStringAsFixed(4)} '
          'samples=$sampleCount baselineSamples=$baselineSamples>>>',
        );

        expect(pcm.isNotEmpty, isTrue, reason: 'PCM output was empty');
        expect(
          rms,
          greaterThan(0.02),
          reason: 'RMS too close to silence: $rms',
        );
        expect(
          sampleCount,
          greaterThanOrEqualTo(baselineSamples),
          reason:
              'Multi-clause audio ($sampleCount samples) shorter than a single-clause '
              'baseline ($baselineSamples samples) — clause concatenation looks broken',
        );
      } finally {
        await synth.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'non-speech clause: "Sounds good! 👍" skips the emoji clause and still speaks the rest',
    (_) async {
      await FlutterEdgeAi.initialize(ttsBackends: const [LiteRtTtsBackend()]);

      await FlutterEdgeAi.installTts()
          .fromNetwork(_modelUrl)
          .ofType(TtsModelType.matcha)
          .install();

      final synth = await FlutterEdgeAi.getActiveTts();

      try {
        // The "👍" clause maps to zero symbols; the fix skips it instead of
        // erroring the whole request, so "Sounds good!" still synthesizes.
        final pcm = await synth.synthesize('Sounds good! 👍');
        final rms = _rms(pcm);

        debugPrint(
          'TTS-ROBUST<<<case=non_speech_clause bytes=${pcm.length} rms=${rms.toStringAsFixed(4)}>>>',
        );

        expect(pcm.isNotEmpty, isTrue, reason: 'PCM output was empty');
        expect(
          rms,
          greaterThan(0.02),
          reason: 'RMS too close to silence: $rms',
        );
      } finally {
        await synth.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
