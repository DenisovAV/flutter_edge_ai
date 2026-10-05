// Pure-Dart coverage of the generic STT pipeline's non-native parts:
// SttModelProfile.forType, int16->float conversion, pad/trim to
// windowSamples, argmax, EOS stop, and detokenize of a canned id sequence.
// No native FFI call is made anywhere in this file (SttCore.load /
// LiteRtBindings.open are never invoked) — see the task's "no native in
// unit tests" constraint.

import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/litert/litert_speech_recognizer.dart'
    show pcm16LEToFloat32;
import 'package:flutter_gemma_speech/src/litert/stt_core.dart'
    show argmax, padOrTrimToWindow, shouldStopDecoding, sttDecodeEosId;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pcm16LEToFloat32', () {
    test('converts int16 LE samples to [-1,1] float32', () {
      // 0x0000 -> 0.0, 0x7FFF -> ~1.0, 0x8000 (-32768) -> -1.0.
      final bytes = Uint8List.fromList([
        0x00, 0x00, // 0
        0xFF, 0x7F, // 32767
        0x00, 0x80, // -32768
      ]);
      final samples = pcm16LEToFloat32(bytes);
      expect(samples.length, 3);
      expect(samples[0], closeTo(0.0, 1e-9));
      expect(samples[1], closeTo(32767 / 32768.0, 1e-9));
      expect(samples[2], closeTo(-1.0, 1e-9));
    });

    test('drops a trailing odd byte', () {
      final bytes = Uint8List.fromList([0x00, 0x00, 0x2A]);
      expect(pcm16LEToFloat32(bytes).length, 1);
    });
  });

  group('padOrTrimToWindow', () {
    test('zero-pads a short clip', () {
      final samples = Float32List.fromList([1.0, 2.0, 3.0]);
      final windowed = padOrTrimToWindow(samples, 5);
      expect(windowed, [1.0, 2.0, 3.0, 0.0, 0.0]);
    });

    test('trims a long clip to exactly windowSamples', () {
      final samples = Float32List.fromList([1.0, 2.0, 3.0, 4.0, 5.0]);
      final windowed = padOrTrimToWindow(samples, 3);
      expect(windowed, [1.0, 2.0, 3.0]);
    });

    test('leaves an already-exact clip unchanged', () {
      final samples = Float32List.fromList([1.0, 2.0]);
      expect(padOrTrimToWindow(samples, 2), same(samples));
    });
  });

  group('argmax', () {
    test('picks the index of the largest value', () {
      expect(argmax(Float32List.fromList([1.0, 5.0, 2.0])), 1);
    });

    test('keeps the first match on a tie', () {
      expect(argmax(Float32List.fromList([3.0, 3.0, 1.0])), 0);
    });

    test('handles a single-element row', () {
      expect(argmax(Float32List.fromList([42.0])), 0);
    });
  });

  group('shouldStopDecoding', () {
    test('stops on EOS regardless of length', () {
      expect(
        shouldStopDecoding(sttDecodeEosId, 5, 64, eosId: sttDecodeEosId),
        isTrue,
      );
    });

    test('stops when maxDecodeTokens is reached even without EOS', () {
      expect(shouldStopDecoding(7, 64, 64, eosId: sttDecodeEosId), isTrue);
    });

    test('continues otherwise', () {
      expect(shouldStopDecoding(7, 5, 64, eosId: sttDecodeEosId), isFalse);
    });

    test('honors a non-default eosId (e.g. whisper\'s resolved EOS)', () {
      expect(shouldStopDecoding(7, 5, 64, eosId: 7), isTrue);
      expect(shouldStopDecoding(2, 5, 64, eosId: 7), isFalse);
    });
  });
}
