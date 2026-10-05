import 'dart:typed_data';
import 'package:flutter_gemma_speech/src/tts/tts_frontend_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MatchaFrontendInput is a TtsFrontendInput carrying the 3 fields', () {
    final i = MatchaFrontendInput(_f, _f, 7);
    expect(i, isA<TtsFrontendInput>());
    expect(i.realLen, 7);
  });
}

final _f = Float32List(0);
