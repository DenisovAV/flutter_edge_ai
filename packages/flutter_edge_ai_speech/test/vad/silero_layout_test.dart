// The tensor layout a Silero VAD model given by path must have, checked at
// load before the probe frame runs.
import 'package:flutter_edge_ai_speech/src/vad/silero_vad_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const good = (
    inputs: [
      [1, 1, 512],
      [1, 320],
    ],
    outputs: [
      [1, 1, 1],
      [1, 320],
    ],
  );

  void check({
    int inputCount = 2,
    List<List<int>>? inputs,
    List<List<int>>? outputs,
  }) => checkSileroVadLayout(
    inputCount: inputCount,
    inputShapes: inputs ?? good.inputs,
    outputShapes: outputs ?? good.outputs,
  );

  test('the bundled layout passes', () => check());

  test('a third input is refused', () {
    expect(() => check(inputCount: 3), throwsFormatException);
  });

  test('a 576-sample audio input is refused', () {
    expect(
      () => check(
        inputs: [
          [1, 1, 576],
          [1, 320],
        ],
      ),
      throwsFormatException,
    );
  });

  test('upstream v5 state [2,1,128] is refused', () {
    expect(
      () => check(
        inputs: [
          [1, 1, 512],
          [2, 1, 128],
        ],
      ),
      throwsFormatException,
    );
  });

  test('outputs in the other order are refused', () {
    expect(
      () => check(
        outputs: [
          [1, 320],
          [1, 1, 1],
        ],
      ),
      throwsFormatException,
    );
  });
}
