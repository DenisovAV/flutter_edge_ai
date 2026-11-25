// On-device voice activity detection through the public API, with the model
// the speech package ships (Silero VAD v6.3, exported to LiteRT for the
// package; see its assets/vad/README.md): no download, no network.
//
// 1. Parity: the speech probability of every 32 ms frame of anira's
//    synthetic test signal, fed as 16-bit PCM, equals the same model run by
//    Google's Python LiteRT (ai-edge-litert 2.3.0) on the same 16-bit
//    samples, within 1e-4. (16-bit rounding alone moves the probabilities by
//    up to 0.034, which is why the golden is taken on the 16-bit samples.)
//    The signal generator is ported to Dart, unchanged in substance, from
//    anira-project/models, models/silero-vad/export/make_vad_golden.py at
//    04edd100eaf3d49e30160a47048b21f35102d882, by the anira-project/models
//    authors, SPDX-License-Identifier: Apache-2.0 (that file's header; the
//    export scripts beside it are MIT), licensed under the Apache
//    License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
//    Modified: ported from Python to Dart; `_signal` below is that port.
// 2. The streaming path on that signal: 200 ms chunks give the events one
//    chunk gives.
// 3. The bundled speech clip: at least one utterance, inside the clip.
// Prints the time per frame.
//
// Run: flutter test integration_test/vad_test.dart -d <device>
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _rate = 16000;
const _wavHeaderBytes = 44;

/// anira's VAD test signal: two phrases of four syllables (a 120 Hz pulse
/// train through formant resonators at 700, 1200 and 2600 Hz, Hann-shaped,
/// 0.25 s on and 0.15 s off) with silence around them; 91,200 samples,
/// float32 as anira writes them.
Float32List _signal() {
  const syllable = _rate ~/ 4;
  const period = _rate ~/ 120;
  final out = <double>[];
  void silence(double seconds) =>
      out.addAll(List.filled((seconds * _rate).toInt(), 0.0));
  void phrase() {
    for (var s = 0; s < 4; s++) {
      var x = List<double>.filled(syllable, 0.0);
      for (var i = 0; i < syllable; i += period) {
        x[i] = 1.0;
      }
      for (final (formant, bandwidth) in const [
        (700.0, 80.0),
        (1200.0, 90.0),
        (2600.0, 120.0),
      ]) {
        final r = math.exp(-math.pi * bandwidth / _rate);
        final a1 = -2.0 * r * math.cos(2.0 * math.pi * formant / _rate);
        final a2 = r * r;
        var y1 = 0.0, y2 = 0.0, peak = 0.0;
        for (var i = 0; i < syllable; i++) {
          final y0 = x[i] - (a1 * y1) - (a2 * y2);
          y2 = y1;
          y1 = y0;
          x[i] = y0;
          peak = math.max(peak, y0.abs());
        }
        x = [for (final v in x) v / peak];
      }
      for (var i = 0; i < syllable; i++) {
        final hann = 0.5 - (0.5 * math.cos(2.0 * math.pi * i / (syllable - 1)));
        out.add(0.3 * x[i] * hann);
      }
      silence(0.15);
    }
  }

  silence(0.5);
  phrase();
  silence(1.0);
  phrase();
  silence(1.0);
  return Float32List.fromList(out);
}

/// [samples] in [-1, 1] as 16-bit PCM, rounded half away from zero (the
/// golden's Python run rounds the same way).
Uint8List _pcm16(Float32List samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i] * 32768).round().clamp(-32768, 32767);
    data.setInt16(i * 2, v, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Silero VAD v6.3 (the bundled LiteRT file) on `_pcm16(_signal())`, run by
/// ai-edge-litert 2.3.0 with the state fed back, one value per whole
/// 512-sample frame, rounded to 7 decimals.
const _golden = <double>[
  0.0108195,
  0.0136513,
  0.0120598,
  0.0130152,
  0.0174089,
  0.0214731,
  0.0239341,
  0.0265843,
  0.0295638,
  0.0330975,
  0.0361704,
  0.0377564,
  0.0386688,
  0.0390403,
  0.0389138,
  0.14183,
  0.8381461,
  0.8067092,
  0.6223077,
  0.5943525,
  0.6638596,
  0.8136078,
  0.899341,
  0.8878683,
  0.668953,
  0.4077925,
  0.0807507,
  0.0260314,
  0.3898375,
  0.605314,
  0.5722833,
  0.436044,
  0.4671174,
  0.4811304,
  0.5258016,
  0.3887131,
  0.1968744,
  0.1115687,
  0.0572651,
  0.0400817,
  0.0959567,
  0.1449442,
  0.1230999,
  0.0481044,
  0.050559,
  0.0667881,
  0.049398,
  0.0571762,
  0.0210392,
  0.0202594,
  0.0129668,
  0.0097235,
  0.0078231,
  0.101771,
  0.0552294,
  0.0627079,
  0.0177335,
  0.0134898,
  0.0168091,
  0.018827,
  0.0113225,
  0.0137182,
  0.007629,
  0.0046671,
  0.0029717,
  0.0022326,
  0.0018423,
  0.0016098,
  0.0014248,
  0.0013224,
  0.0012797,
  0.001264,
  0.001259,
  0.0012597,
  0.001261,
  0.0012699,
  0.0012781,
  0.0012823,
  0.0012819,
  0.0012769,
  0.0012673,
  0.0012543,
  0.0012308,
  0.0012032,
  0.0011748,
  0.001146,
  0.0011173,
  0.001089,
  0.0010613,
  0.0010345,
  0.0010087,
  0.0009841,
  0.0009606,
  0.0009385,
  0.0009176,
  0.0008972,
  0.0012289,
  0.0143409,
  0.013432,
  0.0037544,
  0.0030955,
  0.0037589,
  0.0039153,
  0.0052741,
  0.0039312,
  0.0047986,
  0.0020384,
  0.0016734,
  0.0012544,
  0.013911,
  0.002618,
  0.0029568,
  0.0010233,
  0.0010186,
  0.0024707,
  0.0027681,
  0.0029669,
  0.0028181,
  0.0015855,
  0.0008811,
  0.0007989,
  0.0007277,
  0.0062186,
  0.0064916,
  0.0021618,
  0.0014839,
  0.0016493,
  0.0020899,
  0.0022944,
  0.0019972,
  0.0046563,
  0.0023219,
  0.0022032,
  0.0018075,
  0.013536,
  0.0023005,
  0.0023195,
  0.0007719,
  0.0007693,
  0.0019408,
  0.0021215,
  0.0022343,
  0.002528,
  0.0016497,
  0.0009165,
  0.0008868,
  0.0010681,
  0.001194,
  0.0012929,
  0.0014014,
  0.0014948,
  0.0015746,
  0.0016413,
  0.0016855,
  0.0017073,
  0.0017106,
  0.0016983,
  0.0016739,
  0.0016405,
  0.0016011,
  0.0015582,
  0.0015098,
  0.0014607,
  0.0014134,
  0.0013688,
  0.0013273,
  0.0012929,
  0.0012615,
  0.001233,
  0.0012074,
  0.0011843,
  0.0011637,
  0.0011454,
  0.0011291,
  0.0011147,
  0.001102,
  0.001091,
  0.0010813,
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late VoiceActivityDetector vad;
  setUpAll(() async => vad = await VoiceActivityDetector.create());
  tearDownAll(() => vad.close());

  testWidgets('the bundled model matches the golden', (_) async {
    final signal = _signal();
    expect(signal.length, 91200);
    final watch = Stopwatch()..start();
    final p = await vad.probabilities(_pcm16(signal));
    watch.stop();
    // The golden covers whole frames only; probabilities pads the tail.
    expect(p.length, _golden.length + 1);
    var maxDiff = 0.0;
    for (var i = 0; i < _golden.length; i++) {
      maxDiff = math.max(maxDiff, (p[i] - _golden[i]).abs());
    }
    // ignore: avoid_print
    print(
      'VAD parity: max |p - golden| = ${maxDiff.toStringAsExponential(2)} '
      'over ${_golden.length} frames; '
      '${(watch.elapsedMicroseconds / p.length / 1000).toStringAsFixed(3)} '
      'ms per frame (round trip to the worker included)',
    );
    expect(maxDiff, lessThan(1e-4));
  });

  testWidgets('detect on the signal: 200 ms chunks give the events one chunk '
      'gives', (_) async {
    final pcm = _pcm16(_signal());
    final whole = await vad.detect(Stream.value(pcm)).toList();
    final chunked = await vad
        .detect(
          Stream.fromIterable([
            for (var i = 0; i < pcm.length; i += 6400)
              Uint8List.sublistView(pcm, i, math.min(i + 6400, pcm.length)),
          ]),
        )
        .toList();
    // ignore: avoid_print
    print('VAD events on the signal: $chunked');
    expect(chunked, whole);
    // The model hears the first phrase (0.5-2.1 s); a synthetic formant
    // signal is not speech to Silero for long, so the second may go
    // unheard. Endpointing quality is measured on recorded speech.
    expect(chunked.first, isA<VadSpeechStart>());
    expect(
      (chunked.first as VadSpeechStart).start.inMilliseconds,
      inInclusiveRange(400, 700),
    );
  });

  testWidgets('detect finds speech in the bundled clip', (_) async {
    final wav = await rootBundle.load('assets/test/test_audio.wav');
    final pcm = Uint8List.sublistView(
      wav.buffer.asUint8List(),
      _wavHeaderBytes,
    );
    final clip = Duration(microseconds: pcm.length ~/ 2 * 1000000 ~/ _rate);
    final events = await vad.detect(Stream.value(pcm)).toList();
    // ignore: avoid_print
    print('VAD events on test_audio.wav ($clip): $events');
    final ends = events.whereType<VadSpeechEnd>().toList();
    expect(ends, isNotEmpty);
    for (final end in ends) {
      expect(end.start < end.end, isTrue);
      expect(end.end <= clip, isTrue);
    }
  });
}
