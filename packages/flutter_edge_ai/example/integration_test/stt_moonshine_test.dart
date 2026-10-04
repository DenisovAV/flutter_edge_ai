// On-device STT integration test — installs moonshine-tiny from HuggingFace and
// transcribes the bundled clip through the public API
// (installStt -> getActiveStt -> transcribe). Runs on every native target
// (macOS/iOS/Android/desktop). Web is not covered — the STT web arm is a stub.
//
// Run: flutter test integration_test/stt_moonshine_test.dart -d <device>
//        [--dart-define=HUGGINGFACE_TOKEN=hf_xxx]
// The moonshine HF repos are public, so the token is optional.
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

const _modelUrl =
    'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_f32.tflite';
const _tokenizerUrl =
    'https://huggingface.co/UsefulSensors/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json';
const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'moonshine transcribes the bundled clip via the public STT API',
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
          .ofType(SttModelType.moonshine)
          .install();

      final recognizer = await FlutterEdgeAi.getActiveStt();

      // Bundled 16 kHz mono 16-bit PCM WAV.
      final wav = await rootBundle.load('assets/test/test_audio.wav');
      final pcm = Uint8List.sublistView(
        wav.buffer.asUint8List(),
        _wavHeaderBytes,
      );

      final transcript = await recognizer.transcribe(pcm);
      debugPrint('STT-TEST-TRANSCRIPT<<<$transcript>>>');

      final low = transcript.toLowerCase();
      // Greedy decode is deterministic; assert stable content words rather than
      // exact punctuation/casing. Ground truth: "She had ... watch for all year."
      expect(transcript.trim(), isNotEmpty, reason: 'got: "$transcript"');
      expect(
        low.split(RegExp(r'\s+')).length,
        greaterThanOrEqualTo(5),
        reason: 'expected a full sentence, got: "$transcript"',
      );
      expect(low, contains('she'), reason: 'got: "$transcript"');
      expect(low, contains('watch'), reason: 'got: "$transcript"');
      expect(low, contains('year'), reason: 'got: "$transcript"');

      await recognizer.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
