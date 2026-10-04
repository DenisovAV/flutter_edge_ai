// On-device proof that the Whisper output language is a PER-TRANSCRIPTION
// property (#500) — the claim the unit tests cannot make.
//
// The unit suite proves the plumbing: the value reaches RuntimeConfig, the
// right prompt slot is replaced, the singleton is retargeted. None of that
// proves the model actually writes a different language, because every layer
// below `transcribe` is faked. This file runs the real checkpoint.
//
// Two things are asserted, and the second is the one that was broken:
//   1. the same audio, transcribed twice on ONE recognizer with two different
//      languages, produces two DIFFERENT transcripts;
//   2. it does so without closing or rebuilding anything — `identical()` holds
//      across the `getActiveStt` calls.
//
// The bundled clip is English, so `language: 'de'` asks Whisper to TRANSLATE
// it. That is the documented behaviour (the weights understand the audio either
// way; the token decides the output language), and it is what makes one clip
// enough — no second recording is needed to tell the two runs apart.
//
// Run: flutter test integration_test/whisper_language_test.dart -d <device-id>
//        [--dart-define=HUGGINGFACE_TOKEN=hf_xxx]
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _modelUrl =
    'https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_f32.tflite';
const _tokenizerUrl =
    'https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json';
const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');

/// WAV data chunk starts after the 44-byte canonical PCM header.
const _wavHeaderBytes = 44;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the output language is per-call and needs no reload', (_) async {
    // Everything that can throw lives in the test body, never in setUp: under
    // some runners a throwing setUp is reported as a pass.
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

    final wav = await rootBundle.load('assets/test/test_audio.wav');
    final pcm = Uint8List.sublistView(
      wav.buffer.asUint8List(),
      _wavHeaderBytes,
    );

    final recognizer = await FlutterEdgeAi.getActiveStt();
    try {
      final english = await recognizer.transcribe(pcm);
      debugPrint('STT-LANG<<<en|$english>>>');

      // Per-call override on the SAME recognizer — no close, no reinstall.
      final german = await recognizer.transcribe(pcm, language: 'de');
      debugPrint('STT-LANG<<<de|$german>>>');

      expect(english.trim(), isNotEmpty);
      expect(german.trim(), isNotEmpty);
      expect(
        german.trim(),
        isNot(equals(english.trim())),
        reason:
            'the language token did not reach the decoder: both runs produced '
            '"${english.trim()}"',
      );

      // The second `getActiveStt` is where the shipped bug lived: it returned
      // the recognizer built for the first language and said nothing.
      final retargeted = await FlutterEdgeAi.getActiveStt(language: 'de');
      expect(
        identical(retargeted, recognizer),
        isTrue,
        reason: 'the recognizer was rebuilt; retargeting must not reload',
      );
      expect(retargeted.language, 'de');

      final germanByDefault = await retargeted.transcribe(pcm);
      debugPrint('STT-LANG<<<default-de|$germanByDefault>>>');
      expect(
        germanByDefault.trim(),
        isNot(equals(english.trim())),
        reason:
            'getActiveStt(language:) did not take effect on an existing '
            'recognizer — the #500 regression',
      );

      // A code the checkpoint does not have must fail loudly, not fall back to
      // English and look like success.
      await expectLater(
        recognizer.transcribe(pcm, language: 'zz'),
        throwsArgumentError,
      );
    } finally {
      await recognizer.close();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
