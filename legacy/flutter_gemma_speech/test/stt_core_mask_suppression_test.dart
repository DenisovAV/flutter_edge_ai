import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/litert/stt_core.dart'
    show applySuppression, writeDecoderMask;
import 'package:flutter_gemma_speech/src/model/stt_model_profile.dart'
    show SttDecoderMaskConvention;
import 'package:flutter_gemma_speech/src/tokenizer/stt_special_tokens.dart'
    show ResolvedSuppression;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('writeDecoderMask', () {
    test(
      'paddingOnly: valid iff j<len, identical across every row (moonshine convention C)',
      () {
        const maxTokens = 4;
        final mask = Float32List(maxTokens * maxTokens);
        writeDecoderMask(
          mask,
          maxTokens: maxTokens,
          len: 2,
          convention: SttDecoderMaskConvention.paddingOnly,
        );
        for (var r = 0; r < maxTokens; r++) {
          expect(mask[r * maxTokens + 0], 0.0, reason: 'row $r col 0');
          expect(mask[r * maxTokens + 1], 0.0, reason: 'row $r col 1');
          expect(mask[r * maxTokens + 2], -1e9, reason: 'row $r col 2');
          expect(mask[r * maxTokens + 3], -1e9, reason: 'row $r col 3');
        }
      },
    );

    test('causal: valid iff j<=r AND j<len', () {
      const maxTokens = 4;
      final mask = Float32List(maxTokens * maxTokens);
      writeDecoderMask(
        mask,
        maxTokens: maxTokens,
        len: 3,
        convention: SttDecoderMaskConvention.causal,
      );
      // row 0: only j=0 valid (j<=0 and j<3)
      expect(mask[0 * maxTokens + 0], 0.0);
      expect(mask[0 * maxTokens + 1], -1e9);
      // row 2: j=0,1,2 valid (all <=2 and <3)
      expect(mask[2 * maxTokens + 0], 0.0);
      expect(mask[2 * maxTokens + 1], 0.0);
      expect(mask[2 * maxTokens + 2], 0.0);
      // row 3: j<=3 but j<len(3) caps it at j=0,1,2 -- j=3 invalid (not <3)
      expect(mask[3 * maxTokens + 3], -1e9);
    });
  });

  group('applySuppression', () {
    test('null suppression leaves the row untouched', () {
      final row = Float32List.fromList([1.0, 2.0, 3.0]);
      applySuppression(row, step: 0, suppression: null);
      expect(row, [1.0, 2.0, 3.0]);
    });

    test('forces every id above suppressAboveId to -inf, every step', () {
      final row = Float32List.fromList([1.0, 2.0, 3.0, 4.0, 5.0]);
      const suppression = ResolvedSuppression(
        suppressAboveId: 2,
        suppressAtStepZeroIds: {},
      );
      applySuppression(row, step: 5, suppression: suppression);
      expect(row.sublist(0, 3), [1.0, 2.0, 3.0]);
      expect(row[3], double.negativeInfinity);
      expect(row[4], double.negativeInfinity);
    });

    test('forces suppressAtStepZeroIds to -inf ONLY at step 0', () {
      const suppression = ResolvedSuppression(
        suppressAboveId: 100,
        suppressAtStepZeroIds: {1},
      );
      final atZero = Float32List.fromList([1.0, 2.0, 3.0]);
      applySuppression(atZero, step: 0, suppression: suppression);
      expect(atZero[1], double.negativeInfinity);

      final laterStep = Float32List.fromList([1.0, 2.0, 3.0]);
      applySuppression(laterStep, step: 1, suppression: suppression);
      expect(laterStep[1], 2.0);
    });

    test('argmax never returns a suppressed id', () {
      final row = Float32List.fromList([
        1.0,
        100.0,
        3.0,
      ]); // id 1 is the raw max
      const suppression = ResolvedSuppression(
        suppressAboveId: 100,
        suppressAtStepZeroIds: {1},
      );
      applySuppression(row, step: 0, suppression: suppression);
      var bestIndex = 0;
      var bestValue = row[0];
      for (var i = 1; i < row.length; i++) {
        if (row[i] > bestValue) {
          bestValue = row[i];
          bestIndex = i;
        }
      }
      expect(bestIndex, isNot(1));
    });
  });
}
