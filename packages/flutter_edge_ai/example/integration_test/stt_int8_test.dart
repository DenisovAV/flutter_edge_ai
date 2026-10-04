// On-device STT integration test — installs three small INT8 STT models
// from HuggingFace and transcribes the bundled clip through the public API
// (installStt -> getActiveStt -> transcribe). Runs on every native target
// (macOS/iOS/Android/desktop). Web is not covered — the STT web arm is a
// stub.
//
// These int8 models reuse the already-shipped moonshine/whisper
// SttModelProfiles (zero engine code — SttModelType selects the profile,
// not the quantization). int8 op-coverage/dtype on the f32-proven SttCore
// path is otherwise unverified, so this test is the on-device proof gate
// for each model's `isSupported` flag in `models/stt_model.dart`.
//
// Run: flutter test integration_test/stt_int8_test.dart -d <device-id>
//        [--dart-define=HUGGINGFACE_TOKEN=hf_xxx]
// All three HF repos are public, so the token is optional.
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

/// Ground-truth content words for the bundled clip ("She had your dark suit
/// in greasy wash water all year."). Tiny/base int8 models sometimes mis-hear
/// "watch" as the phonetically close "wash" (same confusion seen on f32 in
/// whisper_tiny_test.dart), so we require at least 2 of 4 hits rather than
/// an exact match.
const _groundTruthWords = ['she', 'watch', 'wash', 'year'];

class _Int8Case {
  const _Int8Case({
    required this.label,
    required this.modelUrl,
    required this.tokenizerUrl,
    required this.sttModelType,
  });

  final String label;
  final String modelUrl;
  final String tokenizerUrl;
  final SttModelType sttModelType;
}

const _cases = [
  _Int8Case(
    label: 'moonshine-tiny-i8',
    modelUrl:
        'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_i8.tflite',
    tokenizerUrl:
        'https://huggingface.co/UsefulSensors/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json',
    sttModelType: SttModelType.moonshine,
  ),
  _Int8Case(
    label: 'whisper-tiny-i8',
    modelUrl:
        'https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_i8.tflite',
    tokenizerUrl:
        'https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json',
    sttModelType: SttModelType.whisper,
  ),
  _Int8Case(
    label: 'whisper-base-i8',
    modelUrl:
        'https://huggingface.co/litert-community/whisper-base/resolve/main/whisper_base_30s_i8.tflite',
    tokenizerUrl:
        'https://huggingface.co/openai/whisper-base/resolve/main/tokenizer.json',
    sttModelType: SttModelType.whisper,
  ),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final testCase in _cases) {
    testWidgets(
      '${testCase.label} transcribes the bundled clip via the public STT '
      'API',
      (_) async {
        await FlutterEdgeAi.initialize(
          huggingFaceToken: _token.isEmpty ? null : _token,
          sttBackends: const [LiteRtSttBackend()],
        );

        await FlutterEdgeAi.installStt()
            .modelFromNetwork(
              testCase.modelUrl,
              token: _token.isEmpty ? null : _token,
            )
            .tokenizerFromNetwork(
              testCase.tokenizerUrl,
              token: _token.isEmpty ? null : _token,
            )
            .ofType(testCase.sttModelType)
            .install();

        final recognizer = await FlutterEdgeAi.getActiveStt();

        // Bundled 16 kHz mono 16-bit PCM WAV.
        final wav = await rootBundle.load('assets/test/test_audio.wav');
        final pcm = Uint8List.sublistView(
          wav.buffer.asUint8List(),
          _wavHeaderBytes,
        );

        final transcript = await recognizer.transcribe(pcm);
        debugPrint(
          'STT-INT8-TEST-TRANSCRIPT[${testCase.label}]'
          '<<<$transcript>>>',
        );

        final low = transcript.toLowerCase();
        expect(transcript.trim(), isNotEmpty, reason: 'got: "$transcript"');
        expect(
          low.split(RegExp(r'\s+')).length,
          greaterThanOrEqualTo(3),
          reason: 'expected a full sentence, got: "$transcript"',
        );
        final hits = _groundTruthWords.where(low.contains).length;
        expect(
          hits,
          greaterThanOrEqualTo(2),
          reason:
              'expected at least 2 of $_groundTruthWords in transcript, '
              'got: "$transcript"',
        );

        await recognizer.close();
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
