import 'dart:typed_data';
import 'package:flutter_edge_ai_example/utils/audio_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'pcmToWav writes a valid RIFF/WAVE header and round-trips via parseWav',
    () {
      final pcm = Uint8List.fromList(List.generate(64, (i) => i % 256));
      final wav = AudioConverter.pcmToWav(pcm, sampleRate: 22050);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(wav.length, 44 + pcm.length);
      final parsed = AudioConverter.parseWav(wav);
      expect(parsed.sampleRate, 22050);
      expect(parsed.channels, 1);
      expect(parsed.pcmData, orderedEquals(pcm));
    },
  );
}
