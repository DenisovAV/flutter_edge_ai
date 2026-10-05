import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/tts/matcha_text_frontend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fe = MatchaTextFrontend(
    symbolToId: {'_': 0, 'a': 1},
    dictionary: {'x': 'aq'}, // 'q' not in table
    embeddingTable: Float32List.fromList([0, 0, 10, 11]),
    nChannels: 2,
    maxText: 8,
  );

  test('unmapped IPA symbol is fail-loud, not silently dropped', () {
    expect(() => fe.encode('x'), throwsA(isA<StateError>()));
  });
}
