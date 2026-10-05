import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/tts/matcha_text_frontend.dart';
import 'package:flutter_gemma_speech/src/tts/tts_frontend_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Tiny 4-symbol table: '_'(0 blank/pad), 'a'(1), 'b'(2), '.'(3); 2 channels.
  final frontend = MatchaTextFrontend(
    symbolToId: {'_': 0, 'a': 1, 'b': 2, '.': 3},
    dictionary: {'ab': 'ab'}, // word "ab" -> IPA "ab"
    embeddingTable: Float32List.fromList([
      0, 0, // id 0
      10, 11, // id 1 ('a')
      20, 21, // id 2 ('b')
      30, 31, // id 3 ('.')
    ]),
    nChannels: 2,
    maxText: 8,
  );

  test('encode blank-intersperses ids, builds mask + gathered embeddings', () {
    final out = frontend.encode('ab.'); // "ab" + trailing '.'
    expect(out, isA<MatchaFrontendInput>());
    // IPA = "ab." -> symbol ids [1,2,3]; realLen = 2*3+1 = 7
    expect(out.realLen, 7);
    // ids: [0,1,0,2,0,3,0,0] (blank-interspersed, positions 1,3,5)
    // mask: 1.0 for t<7 else 0.0
    expect(out.textMask.sublist(0, 7).every((m) => m == 1.0), isTrue);
    expect(out.textMask[7], 0.0);
    // embeddings row for t=1 (id 1) == [10,11]; t=3 (id 2) == [20,21]
    expect(out.symbolEmbeddings.sublist(2, 4), [10, 11]);
    expect(out.symbolEmbeddings.sublist(6, 8), [20, 21]);
    expect(out.symbolEmbeddings.sublist(0, 2), [0, 0]); // blank row
  });

  test('TtsTextFrontend.encode returns MatchaFrontendInput', () {
    expect(frontend.encode('ab.'), isA<MatchaFrontendInput>());
  });

  test('OOV word throws (dictionary-only)', () {
    expect(() => frontend.encode('zzz'), throwsA(isA<StateError>()));
  });
}
