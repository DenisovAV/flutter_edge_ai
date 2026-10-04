import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:edge_ai_quickstart/wav.dart';

void main() {
  test('the header describes the samples that follow it', () {
    final pcm = Uint8List.fromList(List.generate(480, (i) => i % 256));
    final wav = wavFromPcm16(pcm, sampleRate: 24000);
    final header = ByteData.sublistView(wav, 0, 44);

    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(header.getUint32(4, Endian.little), wav.length - 8);
    expect(header.getUint16(22, Endian.little), 1); // mono
    expect(header.getUint32(24, Endian.little), 24000);
    expect(header.getUint32(28, Endian.little), 48000); // bytes per second
    expect(header.getUint16(34, Endian.little), 16);
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(header.getUint32(40, Endian.little), pcm.length);
    expect(wav.sublist(44), pcm);
  });
}
