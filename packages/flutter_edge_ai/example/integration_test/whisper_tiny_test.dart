// On-device STT integration test — installs whisper-tiny from HuggingFace and
// transcribes the bundled clip through the public API
// (installStt -> getActiveStt -> transcribe). Runs on every native target
// (macOS/iOS/Android/desktop). Web is not covered — the STT web arm is a stub.
//
// Run: flutter test integration_test/whisper_tiny_test.dart -d <device-id>
//        [--dart-define=HUGGINGFACE_TOKEN=hf_xxx]
// whisper-tiny's HF repos are public, so the token is optional.
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

const _modelUrl =
    'https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_f32.tflite';
const _tokenizerUrl =
    'https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json';
const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'whisper transcribes the bundled clip via the public STT API',
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
          .ofType(SttModelType.whisper)
          .install();

      final recognizer = await FlutterEdgeAi.getActiveStt();

      // Bundled 16 kHz mono 16-bit PCM WAV (2.9 s -- well under whisper's
      // 30 s window; zero-padded by SttCore.padOrTrimToWindow).
      final wav = await rootBundle.load('assets/test/test_audio.wav');
      final pcm = Uint8List.sublistView(
        wav.buffer.asUint8List(),
        _wavHeaderBytes,
      );

      final transcript = await recognizer.transcribe(pcm);
      debugPrint('STT-TEST-TRANSCRIPT<<<$transcript>>>');

      final low = transcript.toLowerCase();
      // Ground truth: "She had your dark suit in greasy wash water all
      // year." Greedy decode (no beam search) on a 39M-param model; the
      // Phase 0 on-device spike (causal mask + suppression) produced "She
      // had Jedak Su in greasy wash for all year." -- hitting "she"/"year"
      // and misreading "watch" as the phonetically close "wash". Assert
      // stable content words rather than exact wording, tolerating that
      // known confusion.
      expect(transcript.trim(), isNotEmpty, reason: 'got: "$transcript"');
      expect(
        low.split(RegExp(r'\s+')).length,
        greaterThanOrEqualTo(5),
        reason: 'expected a full sentence, got: "$transcript"',
      );
      const groundTruthWords = ['she', 'watch', 'wash', 'year'];
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
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
