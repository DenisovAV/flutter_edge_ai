// On-device voice activity detection through the public API, with the model
// the speech package ships (Silero VAD v6.2.3, the LiteRT export of
// anira-project/silero-vad): no download, no network.
//
// 1. Parity: the speech probability of every 32 ms frame of anira's
//    synthetic test signal, fed as 16-bit PCM, equals the same model run by
//    Google's Python LiteRT (ai-edge-litert 2.4.0) on the same 16-bit
//    samples, within 1e-4. That Python run reproduces anira's own golden
//    (ONNX Runtime on the float32 signal, test/vad_golden.json on Hugging
//    Face anira-project/silero-vad at
//    c302618523e14ea1a7a919df1b796096186513bb) within 1.9e-5 when fed the
//    float32 signal; 16-bit rounding alone moves the probabilities by up to
//    0.034, which is why the golden here is taken on the 16-bit samples. The
//    signal generator is anira-project/models,
//    models/silero-vad/export/make_vad_golden.py (Apache-2.0), ported to Dart
//    unchanged in substance.
// 2. The streaming path on that signal, in 200 ms chunks.
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

/// Silero VAD v6.2.3 (the bundled LiteRT file) on `_pcm16(_signal())`, run by
/// ai-edge-litert 2.4.0 with the state fed back, one value per whole
/// 512-sample frame, rounded to 7 decimals.
const _golden = <double>[
  0.0016697,
  0.0068837,
  0.0089106,
  0.0078571,
  0.0059065,
  0.0059606,
  0.0058532,
  0.0056402,
  0.0054314,
  0.0051992,
  0.0050483,
  0.0049028,
  0.0047359,
  0.0045851,
  0.0044474,
  0.0535458,
  0.6258944,
  0.8900931,
  0.9183397,
  0.9196375,
  0.9156932,
  0.9345505,
  0.9360992,
  0.6049527,
  0.3329034,
  0.1700553,
  0.061861,
  0.0363825,
  0.2680414,
  0.6073708,
  0.7103119,
  0.7507553,
  0.7139317,
  0.6491506,
  0.7191207,
  0.6855798,
  0.5495156,
  0.2587814,
  0.1158429,
  0.0552555,
  0.1426395,
  0.3419893,
  0.3981426,
  0.2585387,
  0.2277106,
  0.21452,
  0.2501276,
  0.3324791,
  0.1630218,
  0.1182182,
  0.0942056,
  0.0500995,
  0.0367378,
  0.1548238,
  0.0953481,
  0.118369,
  0.0705119,
  0.0678309,
  0.0740921,
  0.1022137,
  0.1076908,
  0.0668437,
  0.0479964,
  0.0382187,
  0.0259658,
  0.0218823,
  0.0207203,
  0.0197972,
  0.0195558,
  0.0193814,
  0.0187798,
  0.0178824,
  0.0169143,
  0.0159556,
  0.015053,
  0.0142326,
  0.0134818,
  0.0127989,
  0.0119309,
  0.0110908,
  0.0103263,
  0.0096088,
  0.0089662,
  0.0083635,
  0.0078286,
  0.0073456,
  0.006909,
  0.0065228,
  0.0061717,
  0.0058185,
  0.0054871,
  0.00518,
  0.0048953,
  0.0046312,
  0.0043863,
  0.0041489,
  0.0064474,
  0.0678136,
  0.1274562,
  0.2992786,
  0.1766125,
  0.1558047,
  0.134921,
  0.1895641,
  0.0776141,
  0.0471995,
  0.0239597,
  0.0156063,
  0.0096232,
  0.0534962,
  0.0250876,
  0.0331269,
  0.0198499,
  0.0179674,
  0.014104,
  0.0195305,
  0.0276673,
  0.015455,
  0.012604,
  0.0092349,
  0.0063198,
  0.0079466,
  0.0293276,
  0.0241704,
  0.0403554,
  0.0294035,
  0.0262654,
  0.0233752,
  0.0337357,
  0.0102372,
  0.0066991,
  0.0064581,
  0.0051753,
  0.0045266,
  0.0227978,
  0.0067138,
  0.0104334,
  0.0089426,
  0.0087783,
  0.0073478,
  0.0114387,
  0.0135199,
  0.0045953,
  0.0040451,
  0.0034722,
  0.0031958,
  0.0027825,
  0.0025417,
  0.0024364,
  0.0023996,
  0.0024385,
  0.002465,
  0.002473,
  0.0023824,
  0.0022939,
  0.0022178,
  0.0021502,
  0.0020899,
  0.0020354,
  0.001989,
  0.0019474,
  0.0019092,
  0.0018736,
  0.0018393,
  0.001799,
  0.0017612,
  0.0017215,
  0.0016804,
  0.0016411,
  0.001605,
  0.0015696,
  0.0015351,
  0.0015025,
  0.0014718,
  0.001442,
  0.0014138,
  0.001387,
  0.0013614,
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

  testWidgets('detect on the signal gives the utterance the model hears', (
    _,
  ) async {
    // The model hears the first phrase (frames 16-39 reach 0.94) but not the
    // second: its probabilities there never pass 0.304 (the golden, frames
    // 97-149), below the 0.5 threshold. A synthetic formant signal is not
    // speech to Silero for long; endpointing quality is measured on recorded
    // speech, not here. What this checks is the streaming path: 200 ms
    // chunks give the utterance the frames imply.
    final pcm = _pcm16(_signal());
    final events = await vad
        .detect(
          Stream.fromIterable([
            for (var i = 0; i < pcm.length; i += 6400)
              Uint8List.sublistView(pcm, i, math.min(i + 6400, pcm.length)),
          ]),
        )
        .toList();
    // ignore: avoid_print
    print('VAD events on the signal: $events');
    expect(events, hasLength(2));
    final end = events[1] as VadSpeechEnd;
    // Onset at frame 16 (512 ms) less the 30 ms pad.
    expect(
      (events[0] as VadSpeechStart).start,
      const Duration(milliseconds: 482),
    );
    expect(end.start, const Duration(milliseconds: 482));
    expect(end.reason, VadEndReason.silence);
    expect(end.end.inMilliseconds, inInclusiveRange(1100, 1400));
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
