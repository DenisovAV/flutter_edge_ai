// On-device STT integration test — installs the registry's moonshine-tiny f32
// build (installFromCatalog, pinned to its Hugging Face commit) and transcribes
// the bundled clip through the public API (getActiveStt -> transcribe). Runs on
// every native target (macOS/iOS/Android/desktop). Web is not covered — the STT
// web arm is a stub. A pass prints the registry evidence line.
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

import 'registry_evidence.dart';

const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('moonshine transcribes the bundled clip via the public STT API', (
    _,
  ) async {
    await FlutterEdgeAi.initialize(
      huggingFaceToken: _token.isEmpty ? null : _token,
      sttBackends: const [LiteRtSttBackend()],
    );

    final variant = LiteRtSpeechModels.moonshineTiny.f32;
    await FlutterEdgeAi.installFromCatalog(variant).install();

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
    // No preferredBackend: the recognizer runs on the CPU.
    recordCatalogEvidence(
      variant,
      backend: PreferredBackend.cpu,
      check: 'transcribes the bundled clip',
    );

    await recognizer.close();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
