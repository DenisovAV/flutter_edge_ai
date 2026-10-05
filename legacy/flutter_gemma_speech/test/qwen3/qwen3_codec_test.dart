// Codec chunked-decode golden gate for `Qwen3TtsCore.decodeCodes`.
//
// This test isolates the codec-decoder graph from the talker/MTP: it feeds
// the GOLDEN `frames.json` (all `[T=26, 16]` codes — codebook-0 + the 15 MTP
// residuals, one row per frame, already gated by `qwen3_talker_decode_test
// .dart`/`qwen3_mtp_test.dart`) straight into `decodeCodes`, and asserts the
// returned PCM matches `waveform_f32.bin` (the golden waveform,
// `Qwen3TtsPipeline._decode_codes`'s output on the SAME codes — see
// `tool/qwen3/gen_qwen3_goldens.py`). Because the talker/MTP graphs aren't
// exercised here, `Qwen3TtsCore.load` uses its DEFAULT `talkerFileName`
// (`talker_int4.tflite`, fast) — `decodeCodes` only ever touches the codec
// graph (`codec_decoder_fp32.tflite`, already fp32/bit-exact) and never
// looks at the talker at all.
//
// T=26 is well under the codec's fixed chunk width (64, per
// `qwen3_tts_core.dart`'s `Qwen3TtsCore.load` introspection of
// `codec_decoder_fp32.tflite`'s `args_0` input), so this golden exercises
// exactly ONE codec call with no left context (`i=0` -> `c=min(25,0)=0`).
//
// The second test below (`frames_long.json`/`waveform_long_f32.bin`, T=135
// > 2 * codecChunk) closes that gap: it drives `decodeCodes`'s
// sliding-window loop through 3 windows with the 25-frame left-context
// carry between them (including a final partial window), so the `i - c`
// window origin, the `wav.sublist(c * 1920, ...)` left-context-drop offset,
// and the multi-piece concat are all provably exercised, not just reachable
// by construction.
//
// The model bundle is NOT committed to the repo — see
// `qwen3_prefill_test.dart`'s file header for the same skip-when-absent
// rationale ([_defaultModelDir]/`QWEN3_MODEL_DIR`).
@Tags(['qwen3-artifacts'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma_speech/src/qwen3/qwen3_tts_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Default location of the Qwen3-TTS model snapshot dir — the local
/// HuggingFace cache path for `litert-community/Qwen3-TTS-12Hz-0.6B-Base`.
/// Override with the `QWEN3_MODEL_DIR` environment variable to run against
/// a different snapshot. Mirrors `qwen3_mtp_test.dart`'s identical helper.
String _defaultModelDir() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.cache/huggingface/hub/'
      'models--litert-community--Qwen3-TTS-12Hz-0.6B-Base/snapshots/'
      '66855540b3b34679f06c3ff07859603fc9514c66';
}

String _modelDir() =>
    Platform.environment['QWEN3_MODEL_DIR'] ?? _defaultModelDir();

/// Recursively scans [dir] and returns a basename -> absolute-path map for
/// every regular file found. Mirrors `qwen3_mtp_test.dart`'s identical
/// helper.
Map<String, String> _scanArtifactPaths(String dir) {
  final out = <String, String>{};
  for (final entity in Directory(dir).listSync(recursive: true)) {
    if (entity is File) {
      out[entity.uri.pathSegments.last] = entity.path;
    }
  }
  return out;
}

/// Reads a raw little-endian float32 PCM dump (no header, as written by
/// `numpy.ndarray.tofile`) into a [Float32List]. Copies into a fresh 0-offset
/// buffer first — `File.readAsBytesSync`'s result is not guaranteed to start
/// at a 4-byte-aligned buffer offset — mirroring `npy_reader.dart`'s
/// `_copyToAlignedBuffer` (that helper is private to its own library, so
/// this is a small local re-implementation, not a duplicate export).
Float32List _readRawF32(String path) {
  final bytes = File(path).readAsBytesSync();
  return Float32List.view(Uint8List.fromList(bytes).buffer);
}

/// Pearson correlation coefficient between [a] and [b] (equal length).
double _pearsonCorr(Float32List a, Float32List b) {
  final n = a.length;
  var sumA = 0.0, sumB = 0.0;
  for (var i = 0; i < n; i++) {
    sumA += a[i];
    sumB += b[i];
  }
  final meanA = sumA / n, meanB = sumB / n;
  var numerator = 0.0, denomA = 0.0, denomB = 0.0;
  for (var i = 0; i < n; i++) {
    final da = a[i] - meanA, db = b[i] - meanB;
    numerator += da * db;
    denomA += da * da;
    denomB += db * db;
  }
  return numerator / math.sqrt(denomA * denomB);
}

/// Largest absolute per-sample difference between [a] and [b] (equal
/// length).
double _maxAbsDiff(Float32List a, Float32List b) {
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > m) m = d;
  }
  return m;
}

void main() {
  final modelDir = _modelDir();

  test('Qwen3TtsCore.decodeCodes: PCM matches the PyTorch golden '
      '(waveform_f32.bin)', () async {
    if (!Directory(modelDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model snapshot not found at $modelDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final artifactPaths = _scanArtifactPaths(modelDir);

    // Golden fixtures — committed, always present (no skip-guard needed).
    final framesGolden =
        jsonDecode(
              File('test/golden/qwen3/frames.json').readAsStringSync(),
            )['frames']
            as List;
    final frames = framesGolden
        .map((row) => (row as List).cast<int>())
        .toList(growable: false);
    expect(frames.length, 26);
    expect(frames[0].length, 16);

    final expectedWav = _readRawF32('test/golden/qwen3/waveform_f32.bin');
    expect(expectedWav.length, 49920); // 26 frames * 1920 upsample.

    // Default `talkerFileName` (int4) — this test never touches the talker
    // or MTP graphs, only `decodeCodes` (the codec graph, already fp32).
    final core = await Qwen3TtsCore.load(
      artifactPaths: artifactPaths,
      backend: PreferredBackend.cpu,
    );
    try {
      final wav = core.decodeCodes(frames);

      final corr = _pearsonCorr(wav, expectedWav);
      final maxAbsDiff = _maxAbsDiff(wav, expectedWav);

      // ignore: avoid_print
      print(
        'QWEN3-CODEC-TEST<<<len=${wav.length} expectedLen=${expectedWav.length} '
        'corr=$corr maxAbsDiff=$maxAbsDiff>>>',
      );

      // THE gate: reproduces the PyTorch reference's decoded waveform for
      // the SAME codes. Observed on-device: corr=1.0, maxAbsDiff=0.0 (both
      // run the SAME fp32 codec graph on the SAME codes through the SAME
      // XNNPACK CPU kernels — this is a real bit-exact match, not luck) —
      // thresholds are tight but leave headroom for harmless cross-run FP
      // noise (e.g. reduction-order differences under different threading).
      expect(wav.length, expectedWav.length);
      expect(corr, greaterThan(0.9999));
      expect(maxAbsDiff, lessThan(1e-4));
    } finally {
      core.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Qwen3TtsCore.decodeCodes: multi-window PCM matches the PyTorch golden '
      '(waveform_long_f32.bin, T=135 > codecChunk=64 -> exercises the '
      'sliding-window + 25-frame left-context-carry path)', () async {
    if (!Directory(modelDir).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS model snapshot not found at $modelDir — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final artifactPaths = _scanArtifactPaths(modelDir);

    // Golden fixtures — committed, always present (no skip-guard needed).
    final framesGolden =
        jsonDecode(
              File('test/golden/qwen3/frames_long.json').readAsStringSync(),
            )['frames']
            as List;
    final frames = framesGolden
        .map((row) => (row as List).cast<int>())
        .toList(growable: false);

    // T=135 > 2 * codecChunk (64) — this is THE assertion that proves the
    // sliding-window loop actually runs multiple windows (not just one,
    // like the T=26 golden above): the loop's window advance is
    // `codecChunk - c`, so T > 64 forces at least one extra window with a
    // 25-frame left-context carry, and T > 128 forces a third (partial)
    // window too.
    expect(frames.length, greaterThan(128));
    expect(frames.length, greaterThan(64));
    expect(frames[0].length, 16);

    final expectedWav = _readRawF32('test/golden/qwen3/waveform_long_f32.bin');
    // T frames * 1920 upsample (Qwen3TtsCore._upsampleFactor).
    expect(expectedWav.length, frames.length * 1920);

    // Default `talkerFileName` (int4) — this test never touches the
    // talker or MTP graphs, only `decodeCodes` (the codec graph, already
    // fp32).
    final core = await Qwen3TtsCore.load(
      artifactPaths: artifactPaths,
      backend: PreferredBackend.cpu,
    );
    try {
      final wav = core.decodeCodes(frames);

      final corr = _pearsonCorr(wav, expectedWav);
      final maxAbsDiff = _maxAbsDiff(wav, expectedWav);

      // ignore: avoid_print
      print(
        'QWEN3-CODEC-LONG-TEST<<<len=${wav.length} '
        'expectedLen=${expectedWav.length} frames=${frames.length} '
        'corr=$corr maxAbsDiff=$maxAbsDiff>>>',
      );

      // Same gate as the T=26 test above, on a fixture that forces the
      // multi-window path: a wrong `i - c` window origin, a wrong
      // `wav.sublist(c * 1920, ...)` context-drop offset, or a broken
      // multi-piece concat would all show up here as a correlation/seam
      // mismatch that the single-window T=26 golden cannot catch.
      expect(wav.length, expectedWav.length);
      expect(corr, greaterThan(0.9999));
      expect(maxAbsDiff, lessThan(1e-4));
    } finally {
      core.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
