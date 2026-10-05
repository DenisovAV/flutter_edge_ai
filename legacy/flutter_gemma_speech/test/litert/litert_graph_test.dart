// Pure-Dart coverage of litert_graph.dart's [GraphInput] tagged-union type
// contract: no native FFI call is made anywhere in this file (no
// LiteRtBindings.open(), no loadLiteRtGraph/runLiteRtGraph/
// createF32TensorBuffer/createI32TensorBuffer call) — mirrors
// tts_core_test.dart's "no native in unit tests" constraint. This pins the
// public shape both Matcha (all-F32) and the upcoming Qwen3 talker/codec
// graphs (mixed F32/I32) depend on: each variant carries its own typed
// payload but exposes a common `shape` via the sealed base class.

import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/litert/litert_graph.dart'
    show F32Input, GraphInput, I32Input;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GraphInput', () {
    test('F32Input exposes its shape through the GraphInput base type', () {
      final data = Float32List.fromList([1.0, 2.0, 3.0]);
      final GraphInput input = F32Input([1, 3], data);
      expect(input.shape, [1, 3]);
      expect(input, isA<F32Input>());
      expect((input as F32Input).data, same(data));
    });

    test('I32Input exposes its shape through the GraphInput base type', () {
      final data = Int32List.fromList([5, 6]);
      final GraphInput input = I32Input([1, 2], data);
      expect(input.shape, [1, 2]);
      expect(input, isA<I32Input>());
      expect((input as I32Input).data, same(data));
    });

    test('a mixed-dtype input list keeps each element\'s own payload type', () {
      // This is exactly the shape the Qwen3 talker `decode` signature needs:
      // 58 F32 inputs + 1 I32 input (`input_pos`), in one ordered list.
      final inputs = <GraphInput>[
        F32Input([1, 4], Float32List.fromList([0.0, 1.0, 2.0, 3.0])),
        I32Input([1, 1], Int32List.fromList([7])),
      ];
      expect(inputs[0], isA<F32Input>());
      expect(inputs[1], isA<I32Input>());
      expect(inputs.map((i) => i.shape), [
        [1, 4],
        [1, 1],
      ]);
    });
  });
}
