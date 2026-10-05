// MTP (multi-token-prediction) 16-step inner loop golden gate for
// `Qwen3TtsCore.runMtp`.
//
// This test isolates the MTP graph from the talker: it feeds the GOLDEN
// frame-0 `hidden` (the talker's last hidden state) + `cb0` (=1342, already
// gated by `qwen3_talker_decode_test.dart`) straight from
// `test/golden/qwen3/frame0.json` into `runMtp`, and asserts the returned 15
// residual codes equal `frame0.json.residual` exactly. Because the talker
// isn't exercised here, `Qwen3TtsCore.load` uses its DEFAULT
// `talkerFileName` (`talker_int4.tflite`, fast) rather than the fp32
// artifact `qwen3_talker_decode_test.dart` needs for a bit-exact cb0 —
// `runMtp` only ever touches the MTP graph (`mtp_fp32.tflite`, already
// fp32/bit-exact) and the host tables.
//
// The model bundle is NOT committed to the repo — see
// `qwen3_prefill_test.dart`'s file header for the same skip-when-absent
// rationale ([_defaultModelDir]/`QWEN3_MODEL_DIR`).
@Tags(['qwen3-artifacts'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma_speech/src/qwen3/qwen3_tts_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Default location of the Qwen3-TTS model snapshot dir — the local
/// HuggingFace cache path for `litert-community/Qwen3-TTS-12Hz-0.6B-Base`.
/// Override with the `QWEN3_MODEL_DIR` environment variable to run against
/// a different snapshot. Mirrors `qwen3_talker_decode_test.dart`'s identical
/// helper.
String _defaultModelDir() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.cache/huggingface/hub/'
      'models--litert-community--Qwen3-TTS-12Hz-0.6B-Base/snapshots/'
      '66855540b3b34679f06c3ff07859603fc9514c66';
}

String _modelDir() =>
    Platform.environment['QWEN3_MODEL_DIR'] ?? _defaultModelDir();

/// Recursively scans [dir] and returns a basename -> absolute-path map for
/// every regular file found. Mirrors `qwen3_talker_decode_test.dart`'s
/// identical helper.
Map<String, String> _scanArtifactPaths(String dir) {
  final out = <String, String>{};
  for (final entity in Directory(dir).listSync(recursive: true)) {
    if (entity is File) {
      out[entity.uri.pathSegments.last] = entity.path;
    }
  }
  return out;
}

void main() {
  final modelDir = _modelDir();

  test('Qwen3TtsCore.runMtp: frame-0 residual matches the PyTorch golden '
      '(frame0.json.residual)', () async {
    if (!Directory(modelDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model snapshot not found at $modelDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final artifactPaths = _scanArtifactPaths(modelDir);

    // Golden fixtures — committed, always present (no skip-guard needed).
    final frame0Golden =
        jsonDecode(File('test/golden/qwen3/frame0.json').readAsStringSync())
            as Map<String, dynamic>;
    final hidden = Float32List.fromList(
      (frame0Golden['hidden'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
    );
    final cb0 = frame0Golden['cb0'] as int;
    final expectedResidual = (frame0Golden['residual'] as List).cast<int>();
    expect(hidden.length, 1024);
    expect(cb0, 1342);
    expect(expectedResidual.length, 15);

    // Default `talkerFileName` (int4) — this test never calls
    // runPrefill/runDecode, so the talker's precision doesn't matter; only
    // the MTP graph (already fp32) is exercised.
    final core = await Qwen3TtsCore.load(
      artifactPaths: artifactPaths,
      backend: PreferredBackend.cpu,
    );
    try {
      final residual = core.runMtp(hidden, cb0);

      // ignore: avoid_print
      print(
        'QWEN3-MTP-TEST<<<cb0=$cb0 residual=$residual '
        'expectedResidual=$expectedResidual>>>',
      );

      // THE gate: reproduces the PyTorch reference's frame-0 residual
      // codebooks exactly.
      expect(residual, expectedResidual);
    } finally {
      core.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
