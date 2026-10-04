// On-device STT integration test — installs parakeet-ctc-0.6b from
// HuggingFace and transcribes the bundled clip through the public API
// (installStt -> getActiveStt -> transcribe). Desktop-only (2.35 GB f32) —
// run on macOS/Windows/Linux. Web and mobile are not covered (see the
// design spec's "Out of scope").
//
// Run: flutter test integration_test/parakeet_ctc_test.dart -d <device-id>
//        [--dart-define=HUGGINGFACE_TOKEN=hf_xxx]
// parakeet's HF repos are public, so the token is optional.
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

const _modelUrl =
    'https://huggingface.co/litert-community/parakeet-ctc-0.6b/resolve/main/parakeet_ctc_0.6b_5s_f32.tflite';
const _tokenizerUrl =
    'https://huggingface.co/nvidia/parakeet-ctc-0.6b/resolve/main/tokenizer.json';
const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'parakeet transcribes the bundled clip via the public STT API',
    (_) async {
      await FlutterEdgeAi.initialize(
        huggingFaceToken: _token.isEmpty ? null : _token,
        sttBackends: const [LiteRtSttBackend()],
      );

      await FlutterEdgeAi.installStt()
          .modelFromNetwork(_modelUrl, token: _token.isEmpty ? null : _token)
          .tokenizerFromNetwork(
            _tokenizerUrl,
            token: _token.isEmpty ? null : _token,
          )
          .ofType(SttModelType.parakeet)
          .install();

      final recognizer = await FlutterEdgeAi.getActiveStt();

      // Bundled 16 kHz mono 16-bit PCM WAV (2.9 s -- well under parakeet's
      // 5 s window; zero-padded by SttCore.padOrTrimToWindow).
      final wav = await rootBundle.load('assets/test/test_audio.wav');
      final pcm = Uint8List.sublistView(
        wav.buffer.asUint8List(),
        _wavHeaderBytes,
      );

      final transcript = await recognizer.transcribe(pcm);
      debugPrint('PARAKEET-TEST-TRANSCRIPT<<<$transcript>>>');

      final low = transcript.toLowerCase();
      // Ground truth: "She had your dark suit in greasy wash water all
      // year." The Phase 0 spike (greedy CTC, 0.6B params) produced "she
      // had your duck suit and greasy wash water all year" — 6 of 7 gate
      // words, missing only "dark". Assert stable content words rather
      // than exact wording.
      expect(transcript.trim(), isNotEmpty, reason: 'got: "$transcript"');
      expect(
        low.split(RegExp(r'\s+')).length,
        greaterThanOrEqualTo(5),
        reason: 'expected a full sentence, got: "$transcript"',
      );
      const groundTruthWords = [
        'she',
        'dark',
        'suit',
        'greasy',
        'wash',
        'water',
        'year',
      ];
      final hits = groundTruthWords.where(low.contains).length;
      expect(
        hits,
        greaterThanOrEqualTo(2),
        reason:
            'expected at least 2 of $groundTruthWords in transcript, '
            'got: "$transcript"',
      );

      await recognizer.close();
    },
    // 2.35 GB f32 download + XNNPACK CPU compile is materially slower than
    // whisper-tiny's 151 MB / moonshine's 109 MB — a longer budget than
    // their 10-minute timeout avoids a flaky false failure on a slow link.
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
