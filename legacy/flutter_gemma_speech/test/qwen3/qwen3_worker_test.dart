// Worker-branch smoke test for the Qwen3-TTS arm of `_workerEntry`
// (`tts_worker.dart`, Task 5.3): spawns a REAL `TtsWorker` against the qwen3
// profile and asserts `synthesize` drives the full AR pipeline
// (`Qwen3TtsCore`, no clause-splitting/CFM seed) end to end, on a
// background isolate, returning plausible int16 PCM.
//
// Unlike `qwen3_synthesize_test.dart` (which drives `Qwen3TtsCore.synthesize`
// directly, greedy, against a byte-exact fp32 golden), this test goes
// through the PUBLIC worker API the runtime actually uses
// (`LiteRtSpeechSynthesizer` -> `TtsWorker.spawn` -> `_workerEntry`), with
// the DEFAULT (int4) talker — fast — and `doSample: true` (the runtime
// default per Task 5.3's brief). So this test asserts PLAUSIBILITY
// (non-empty PCM, duration/rms in a sane band), not bit-exactness — int4 +
// sampling means exact bytes are not reproducible across runs/backends.
//
// The model bundle is NOT committed to the repo — see
// `qwen3_synthesize_test.dart`'s file header for the same skip-when-absent
// rationale ([_defaultModelDir]/`QWEN3_MODEL_DIR`).
@Tags(['qwen3-artifacts'])
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma_speech/src/litert/tts_worker.dart';
import 'package:flutter_gemma_speech/src/model/tts_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// Default location of the Qwen3-TTS model snapshot dir — the local
/// HuggingFace cache path for `litert-community/Qwen3-TTS-12Hz-0.6B-Base`.
/// Override with the `QWEN3_MODEL_DIR` environment variable. Mirrors every
/// other `test/qwen3/*_test.dart`'s identical helper.
String _defaultModelDir() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.cache/huggingface/hub/'
      'models--litert-community--Qwen3-TTS-12Hz-0.6B-Base/snapshots/'
      '66855540b3b34679f06c3ff07859603fc9514c66';
}

String _modelDir() =>
    Platform.environment['QWEN3_MODEL_DIR'] ?? _defaultModelDir();

/// Recursively scans [dir] and returns a basename -> absolute-path map for
/// every regular file found. Mirrors `qwen3_synthesize_test.dart`'s
/// identical helper — this is exactly the shape `artifactPaths` has at
/// runtime (core's model manager resolves the qwen3 bundle's 9 manifest
/// basenames -> on-disk paths; see Task 5.2's report).
Map<String, String> _scanArtifactPaths(String dir) {
  final out = <String, String>{};
  for (final entity in Directory(dir).listSync(recursive: true)) {
    if (entity is File) {
      out[entity.uri.pathSegments.last] = entity.path;
    }
  }
  return out;
}

/// Root-mean-square of 16-bit LE mono PCM [pcm], normalized to `[-1, 1]` —
/// a coarse "is this real audio, not silence or garbage" signal.
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

void main() {
  final modelDir = _modelDir();

  test('TtsWorker (qwen3 profile): synthesize runs the AR pipeline '
      'end-to-end on a background isolate and returns plausible PCM', () async {
    if (!Directory(modelDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model snapshot not found at $modelDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }
    final artifactPaths = _scanArtifactPaths(modelDir);
    if (!artifactPaths.containsKey('talker_int4.tflite')) {
      markTestSkipped(
        'talker_int4.tflite not found under $modelDir — the worker loads '
        'the default (int4) talker, not the fp32 golden-gate artifact.',
      );
      return;
    }

    final worker = await TtsWorker.spawn(
      profile: const TtsModelProfile.qwen3(),
      artifactPaths: artifactPaths,
      backend: PreferredBackend.cpu,
    );
    try {
      // Learned from the load handshake (`core.sampleRate`, `Qwen3TtsCore`'s
      // fixed 24 kHz output) without a round-trip.
      expect(worker.sampleRate, 24000);

      final started = DateTime.now();
      final pcm = await worker.synthesize(
        'Hello from on device text to speech.',
      );
      final elapsed = DateTime.now().difference(started);

      final durationSeconds = pcm.length / 2 / worker.sampleRate;
      final rms = _rms(pcm);

      // ignore: avoid_print
      print(
        'QWEN3-WORKER-TEST<<<pcmBytes=${pcm.length} '
        'durationSeconds=$durationSeconds rms=$rms '
        'elapsedMs=${elapsed.inMilliseconds}>>>',
      );

      expect(pcm, isNotEmpty);
      // Plausibility, not bit-exactness (int4 + doSample:true is not
      // reproducible across runs/backends): ~7 words of speech should take
      // at least ~1s, and per `Qwen3TtsCore.synthesize`'s doc comment, no
      // more than `maxFrames=512` frames' worth (~41s).
      expect(durationSeconds, greaterThanOrEqualTo(1.0));
      expect(durationSeconds, lessThan(41.0));
      // Non-silent, non-clipped-garbage: real speech RMS sits well below
      // full-scale but well above silence.
      expect(rms, greaterThan(0.005));
      expect(rms, lessThan(0.9));
    } finally {
      await worker.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
