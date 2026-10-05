// Tests for the .npy / .npz reader used by the Qwen3-TTS pipeline to load
// host-side model tables (embedding tables, projection matrices, prompt
// caches) shipped as NumPy arrays.
//
// Fixtures live under test/golden/qwen3/npy/ (generated via numpy, see
// task-1.1-brief.md for the exact generation snippet) and
// test/golden/qwen3/prompt.npz (committed in Task 0 — do not regenerate).

import 'dart:io';

import 'package:flutter_gemma_speech/src/qwen3/npy_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('readNpyF32', () {
    test('reads <f4 npy whole', () {
      final a = readNpyF32('test/golden/qwen3/npy/f4_2x3.npy');
      expect(a, orderedEquals([0, 1, 2, 3, 4, 5].map((e) => e.toDouble())));
    });
  });

  group('parseNpyHeader / readNpyF16AsF32 / npyRowF16AsF32', () {
    test('reads <f2 npy row by offset == whole-array row', () {
      final f = File('test/golden/qwen3/npy/f2_4x5.npy').openSync();
      final h = parseNpyHeader(f);
      expect(h.shape, [4, 5]);
      expect(h.dtype, '<f2');

      final whole = readNpyF16AsF32('test/golden/qwen3/npy/f2_4x5.npy');
      final row2 = npyRowF16AsF32(f, h, 2);
      expect(row2, orderedEquals(whole.sublist(10, 15)));
      f.closeSync();
    });
  });

  group('readNpzF32', () {
    test('reads npz members', () {
      final m = readNpzF32('test/golden/qwen3/prompt.npz');
      expect(m.keys, containsAll(['prefill', 'trailing', 'tts_pad']));
    });
  });
}
