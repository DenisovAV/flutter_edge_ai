import 'dart:typed_data';

import 'package:flutter_edge_ai_speech/src/vad/pcm16_framer.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pcm(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('whole frames come out as [-1, 1] floats, the rest is carried', () {
    final framer = Pcm16Framer(4);
    expect(framer.add(pcm([0, 16384, -32768])), isEmpty);
    final out = framer.add(pcm([32767, 1, 2, 3, 4, 5]));
    expect(out, hasLength(8));
    expect(out[1], 0.5);
    expect(out[2], -1.0);
    expect(out[3], closeTo(32767 / 32768, 1e-9));
    expect(framer.totalSamples, 9);
    final tail = framer.flushPadded();
    expect(tail, hasLength(4));
    expect(tail[0], closeTo(5 / 32768, 1e-9));
    expect(tail.sublist(1), [0, 0, 0]);
    expect(framer.flushPadded(), isEmpty);
  });

  test('a sample split across chunks is joined', () {
    final framer = Pcm16Framer(2);
    final bytes = pcm([1000, -1000, 2000, -2000]);
    final out = <double>[];
    for (var i = 0; i < bytes.length; i++) {
      out.addAll(framer.add(Uint8List.fromList([bytes[i]])));
    }
    expect(out.map((s) => (s * 32768).round()), [1000, -1000, 2000, -2000]);
    expect(framer.totalSamples, 4);
  });

  test('frames are identical whatever the chunk sizes', () {
    final samples = List.generate(5000, (i) => (i * 37 % 65536) - 32768);
    final bytes = pcm(samples);
    final whole = Pcm16Framer(512).add(bytes);
    for (final size in [1, 3, 511, 1024, 1025]) {
      final framer = Pcm16Framer(512);
      final out = <double>[];
      for (var i = 0; i < bytes.length; i += size) {
        final end = i + size > bytes.length ? bytes.length : i + size;
        out.addAll(framer.add(Uint8List.sublistView(bytes, i, end)));
      }
      expect(out, whole, reason: 'chunk size $size');
    }
  });
}
