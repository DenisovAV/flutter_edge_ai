import 'package:flutter_gemma_speech/src/tts/neural_g2p_decode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final char2idx = {'<en_us>': 1, '<end>': 2, 'h': 10, 'i': 11};
  test('encode frames char_repeats=3 + start/end, pads to 96, float', () {
    final x = encodeG2pInput('hi', char2idx);
    expect(x.length, 96);
    expect(x.sublist(0, 8), [
      1,
      10,
      10,
      10,
      11,
      11,
      11,
      2,
    ]); // <en_us> h h h i i i <end>
    expect(x.sublist(8).every((v) => v == 0.0), isTrue);
  });
  test(
    'decode truncates at first <end>, collapses, drops specials + lossy',
    () {
      // raw idx: <en_us> h h h ˈ _ ɛ l l <end> [garbage...]
      final idx2ph = {
        1: '<en_us>',
        2: '<end>',
        10: 'h',
        51: 'ˈ',
        0: '_',
        37: 'ɛ',
        13: 'l',
        59: '͡',
      };
      final argmax = [
        1,
        10,
        10,
        10,
        51,
        0,
        37,
        13,
        13,
        2,
        46,
        46,
        46,
      ]; // tail after <end> ignored
      expect(decodeG2pOutput(argmax, idx2ph), 'hˈɛl');
    },
  );
  test('lossy tie-bar U+0361 is dropped', () {
    final idx2ph = {2: '<end>', 20: 't', 59: '͡', 45: 'ʃ'};
    expect(decodeG2pOutput([20, 59, 45, 2], idx2ph), 'tʃ');
  });
  test('decode throws StateError on argmax id missing from idx2ph (fail-loud, '
      'not a silent blank)', () {
    // idx2ph is missing an entry for id 99, which appears in argmax.
    final idx2ph = {1: '<en_us>', 2: '<end>', 10: 'h'};
    final argmax = [1, 10, 99, 2];
    expect(() => decodeG2pOutput(argmax, idx2ph), throwsA(isA<StateError>()));
  });
  test('encode throws StateError when framed ids exceed maxT', () {
    // charRepeats=3 default: 1 (start) + 3*len(word) + 1 (end) must be <=
    // maxT. Use a tiny maxT so a short word already overflows it.
    expect(
      () => encodeG2pInput('hi', char2idx, maxT: 4),
      throwsA(isA<StateError>()),
    );
  });
}
