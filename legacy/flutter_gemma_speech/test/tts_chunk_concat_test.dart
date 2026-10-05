import 'dart:typed_data';
import 'package:flutter_gemma_speech/src/litert/tts_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concatPcmWithSilence joins segments with a silence gap', () {
    final a = Uint8List.fromList([1, 2]);
    final b = Uint8List.fromList([3, 4]);
    final out = concatPcmWithSilence([
      a,
      b,
    ], silenceSamples: 1); // 1 sample = 2 bytes
    expect(out, Uint8List.fromList([1, 2, 0, 0, 3, 4]));
  });

  test('a single segment is returned with no gap inserted', () {
    final a = Uint8List.fromList([9, 8, 7, 6]);
    final out = concatPcmWithSilence([a], silenceSamples: 5);
    expect(out, Uint8List.fromList([9, 8, 7, 6]));
  });

  test('an empty segment list produces empty output', () {
    final out = concatPcmWithSilence(<Uint8List>[], silenceSamples: 3);
    expect(out, isEmpty);
  });

  test('zero silenceSamples concatenates with no gap', () {
    final a = Uint8List.fromList([1, 2]);
    final b = Uint8List.fromList([3, 4]);
    final c = Uint8List.fromList([5, 6]);
    final out = concatPcmWithSilence([a, b, c], silenceSamples: 0);
    expect(out, Uint8List.fromList([1, 2, 3, 4, 5, 6]));
  });

  test('three segments insert a gap BETWEEN each, not around the ends', () {
    final a = Uint8List.fromList([1, 1]);
    final b = Uint8List.fromList([2, 2]);
    final c = Uint8List.fromList([3, 3]);
    final out = concatPcmWithSilence([a, b, c], silenceSamples: 1);
    expect(out, Uint8List.fromList([1, 1, 0, 0, 2, 2, 0, 0, 3, 3]));
  });
}
