// On-device (macOS/desktop): verify the Inflect-Nano-v2 FFI synthesis core
// byte-matches the reference. The fixture (`inflect_fixture.bin`, staged in the
// app documents dir) carries, per sentence: the phoneme ids, the reference
// numpy RandomState(7) noise, and the expected fp16 LiteRT waveform. Injecting
// the reference noise (InflectTtsCore.synthesize's `noiseOverride`) removes the
// RNG as a variable, so this checks the FFI graphs + host length-regulator +
// PCM path against a self-consistent fp16 reference. VITS noise is stochastic,
// so a DIFFERENT noise realization would decorrelate to ~0 — hence the inject.
//
// Stage first:
//   inflect_{text_encoder,decoder}_fp16.tflite + inflect_fixture.bin
//   into the app documents dir.
// Run: cd packages/flutter_edge_ai/example && \
//   flutter test integration_test/inflect_tts_test.dart -d macos
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show PreferredBackend;
// ignore: implementation_imports
import 'package:flutter_edge_ai_speech/src/litert/inflect_tts_core.dart';
// ignore: implementation_imports
import 'package:flutter_edge_ai_speech/src/model/tts_model_profile.dart';
// ignore: implementation_imports
import 'package:flutter_edge_ai_speech/src/tts/inflect_text_frontend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

double _pearson(Float32List a, Float32List b) {
  final n = math.min(a.length, b.length);
  var sa = 0.0, sb = 0.0;
  for (var i = 0; i < n; i++) {
    sa += a[i];
    sb += b[i];
  }
  final ma = sa / n, mb = sb / n;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < n; i++) {
    final x = a[i] - ma, y = b[i] - mb;
    num += x * y;
    da += x * x;
    db += y * y;
  }
  return num / (math.sqrt(da) * math.sqrt(db));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Inflect FFI synthesis byte-matches the fp16 reference (per sentence)',
    (tester) async {
      final docs = await getApplicationDocumentsDirectory();
      final encPath = '${docs.path}/inflect_text_encoder_fp16.tflite';
      final decPath = '${docs.path}/inflect_decoder_fp16.tflite';
      final fixPath = '${docs.path}/inflect_fixture.bin';
      for (final p in [encPath, decPath, fixPath]) {
        expect(
          File(p).existsSync(),
          isTrue,
          reason: 'stage $p (models + inflect_fixture.bin) in app documents',
        );
      }

      final core = await InflectTtsCore.load(
        profile: const TtsModelProfile.inflect(),
        artifactPaths: {
          'inflect_text_encoder_fp16.tflite': encPath,
          'inflect_decoder_fp16.tflite': decPath,
        },
        backend: PreferredBackend.cpu,
      );
      addTearDown(core.dispose);

      final bd = ByteData.sublistView(await File(fixPath).readAsBytes());
      var off = 0;
      int readI32() {
        final v = bd.getInt32(off, Endian.little);
        off += 4;
        return v;
      }

      Int32List readI32Array(int n) {
        final a = Int32List(n);
        for (var i = 0; i < n; i++) {
          a[i] = bd.getInt32(off, Endian.little);
          off += 4;
        }
        return a;
      }

      Float32List readF32Array(int n) {
        final a = Float32List(n);
        for (var i = 0; i < n; i++) {
          a[i] = bd.getFloat32(off, Endian.little);
          off += 4;
        }
        return a;
      }

      final nSent = readI32();
      expect(nSent, greaterThan(0));
      for (var s = 0; s < nSent; s++) {
        final ids = readI32Array(readI32());
        final tFrames = readI32();
        final noise = readF32Array(tFrames * 128);
        final refWav = readF32Array(readI32());

        final pcm = core.synthesize(ids.toList(), noiseOverride: noise);
        final pcmBd = ByteData.sublistView(pcm);
        final got = Float32List(pcm.length ~/ 2);
        for (var i = 0; i < got.length; i++) {
          got[i] = pcmBd.getInt16(i * 2, Endian.little) / 32767.0;
        }

        final corr = _pearson(got, refWav);
        debugPrint(
          '[inflect] sentence $s: N=${ids.length} T=$tFrames '
          'samples=${refWav.length} corr=${corr.toStringAsFixed(6)}',
        );
        expect(
          corr,
          greaterThan(0.99),
          reason:
              'sentence $s: Dart FFI output decorrelates from the '
              'reference (corr=$corr) — FFI graph or host math is off',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'Inflect end-to-end: text -> frontend (dict + neural OOV) -> synth -> '
    'non-silent 24 kHz audio',
    (tester) async {
      final docs = await getApplicationDocumentsDirectory();
      String p(String f) => '${docs.path}/$f';
      final paths = <String, String>{
        'inflect_text_encoder_fp16.tflite': p(
          'inflect_text_encoder_fp16.tflite',
        ),
        'inflect_decoder_fp16.tflite': p('inflect_decoder_fp16.tflite'),
        'config.json': p('config.json'),
        'g2p_dict.txt.gz': p('g2p_dict.txt.gz'),
        'dp_g2p_matcha_fp16.tflite': p('dp_g2p_matcha_fp16.tflite'),
        'g2p_meta.json': p('g2p_meta.json'),
      };
      for (final f in paths.values) {
        expect(
          File(f).existsSync(),
          isTrue,
          reason: 'stage $f in app documents',
        );
      }

      const profile = TtsModelProfile.inflect();
      final core = await InflectTtsCore.load(
        profile: profile,
        artifactPaths: paths,
        backend: PreferredBackend.cpu,
      );
      addTearDown(core.dispose);
      expect(core.neuralG2p, isNotNull, reason: 'dp_g2p should have loaded');

      final fe = await InflectTextFrontend.load(
        profile,
        paths,
        neuralG2p: core.neuralG2p,
      );

      // "flutter"/"gemma"/"speaking" exercise the neural OOV G2P (not all in
      // the dictionary), so this covers the full frontend path end to end.
      const text = 'Hello there, this is flutter gemma speaking.';
      final ids = fe.encode(text);
      expect(ids, isNotEmpty);

      final pcm = core.synthesize(ids);
      expect(
        pcm.length,
        greaterThan(24000),
        reason: 'expected > ~0.5 s of 16-bit 24 kHz audio',
      );
      final bd = ByteData.sublistView(pcm);
      var nonZero = 0;
      final n = pcm.length ~/ 2;
      for (var i = 0; i < n; i++) {
        if (bd.getInt16(i * 2, Endian.little) != 0) nonZero++;
      }
      debugPrint(
        '[inflect-e2e] "$text" -> ${ids.length} ids -> $n samples '
        '($nonZero non-zero)',
      );
      expect(
        nonZero,
        greaterThan(n ~/ 4),
        reason: 'reply audio is mostly silence',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
