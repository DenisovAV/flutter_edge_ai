// Copyright 2026 The ODML Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Modified: ported from C++ (LiteRT-LM v0.19.1,
// omni/speech2text/tokenizer_detokenizer_test.cc) to Dart for
// flutter_edge_ai_speech.
//
// The C++ FakeTokenizer's `TokenIdsToText` callback becomes the
// `TokenIdsToUtf8` function handed to the detokenizer; it returns bytes, so
// the byte strings of the C++ fakes ("\xce\xa9", "\xE4\xB8") are kept exact.
//
// Not ported:
// - ResetClearsOutputs: it checks that Reset() empties the C++ stage's output
//   queue (HasOutput()). The Dart detokenizer returns its words from
//   `detokenize` and keeps no output queue; TokenizerDetokenizer overrides no
//   ResetInternal, so there is no other state for a reset to clear.

import 'dart:convert';

import 'package:flutter_edge_ai_speech/src/streaming/detokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

bool _sameIds(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; ++i) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<int> _s(String text) => utf8.encode(text);

/// Mirrors the C++ fake: the callback ignores `skipSpecialTokens`, and with no
/// callback every decode is empty.
final class _FakeTokenizer {
  List<int> Function(List<int> ids)? tokenIdsToTextFn;

  List<int> tokenIdsToUtf8(List<int> ids, {required bool skipSpecialTokens}) =>
      tokenIdsToTextFn?.call(ids) ?? const [];
}

List<(String, int)> _pairs(List<DetokenizedWord> words) => [
  for (final w in words) (w.text, w.timestampMs ?? -1),
];

void main() {
  group('TokenizerDetokenizerTest', () {
    test('ProcessEmptyTokensReturnsEmptyVector', () {
      final fake = _FakeTokenizer()..tokenIdsToTextFn = (ids) => _s('');
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      expect(detokenizer.detokenize([]), isEmpty);
    });

    test('ProcessTokensDecodesWordsWithTimestamps', () {
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) =>
            _sameIds(ids, [101, 102]) ? _s('hello world') : _s('');
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      final words = detokenizer.detokenize([
        const DecodedToken(101, timestampMs: 100),
        const DecodedToken(102, timestampMs: 200),
      ]);

      expect(words, hasLength(2));
      expect(words[0].text, 'hello');
      expect(words[0].timestampMs, 100);
      expect(words[1].text, 'world');
      expect(words[1].timestampMs, 200);
    });

    test('ProcessTokensInterpolatesTimestampsWhenCountsDiffer', () {
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) =>
            _sameIds(ids, [1, 2, 3, 4, 5]) ? _s('one two three') : _s('');
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);
      final tokens = [
        const DecodedToken(1, timestampMs: 100),
        const DecodedToken(2, timestampMs: 200),
        const DecodedToken(3, timestampMs: 300),
        const DecodedToken(4, timestampMs: 400),
        const DecodedToken(5, timestampMs: 500),
      ];

      final words = detokenizer.detokenize(tokens);

      expect(words, hasLength(3));
      expect(words[0].text, 'one');
      expect(words[0].timestampMs, 100); // Token 0
      expect(words[1].text, 'two');
      expect(words[1].timestampMs, 300); // Token 2
      expect(words[2].text, 'three');
      expect(words[2].timestampMs, 500); // Token 4

      // Single-word multi-token chunk also falls back to token 0 (onset) when
      // per-piece decoding yields empty strings.
      fake.tokenIdsToTextFn = (ids) =>
          _sameIds(ids, [1, 2, 3, 4, 5]) ? _s('unfortunately') : _s('');
      final singleWord = detokenizer.detokenize(tokens);
      expect(singleWord, hasLength(1));
      expect(singleWord[0].text, 'unfortunately');
      expect(singleWord[0].timestampMs, 100); // Token 0 (not Token 4)
    });

    test('ProcessTokensMapsMultiTokenSubwordsToWordOnsetTimestamps', () {
      const pieces = ['Th', 'ere', "'s", ' his', ' be', 'ak', '.', ' But'];
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) {
          final out = StringBuffer();
          for (final id in ids) {
            if (id >= 0 && id < pieces.length) out.write(pieces[id]);
          }
          return _s(out.toString());
        };
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      final words = detokenizer.detokenize([
        const DecodedToken(0, timestampMs: 11),
        const DecodedToken(1, timestampMs: 13),
        const DecodedToken(2, timestampMs: 14),
        const DecodedToken(3, timestampMs: 14),
        const DecodedToken(4, timestampMs: 17),
        const DecodedToken(5, timestampMs: 20),
        const DecodedToken(6, timestampMs: 38),
        const DecodedToken(7, timestampMs: 42),
      ]);

      expect(words, hasLength(4));
      expect(words[0].text, "There's");
      expect(words[0].timestampMs, 11); // Token 0 ("Th")
      expect(words[1].text, 'his');
      expect(words[1].timestampMs, 14); // Token 3 (" his")
      expect(words[2].text, 'beak.');
      expect(words[2].timestampMs, 17); // Token 4 (" be")
      expect(words[3].text, 'But');
      expect(words[3].timestampMs, 42); // Token 7 (" But")
    });

    test('CachesDecodedTokenPiecesAndPreservesLeadingSpaceBoundaries', () {
      const pieces = [' There', "'s", ' his', ' be', 'ak'];
      var callCount = 0;
      var pieceDecodeCalls = 0;
      var maxPieceDecodeLen = 0;
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) {
          ++callCount;
          // Full-chunk decodes pass all 5 tokens; per-piece lookups pass <= 3
          // tokens.
          if (ids.length < 5) {
            ++pieceDecodeCalls;
            if (ids.length > maxPieceDecodeLen) maxPieceDecodeLen = ids.length;
          }
          var out = '';
          for (final id in ids) {
            if (id >= 0 && id < pieces.length) out += pieces[id];
          }
          // Simulate SentencePiece / HuggingFace Metaspace stripping the
          // leading space at the start of a decoded sequence.
          if (out.isNotEmpty && out.startsWith(' ')) {
            out = out.substring(1);
          }
          return _s(out);
        };
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      final words1 = detokenizer.detokenize([
        const DecodedToken(0, timestampMs: 10),
        const DecodedToken(1, timestampMs: 12),
        const DecodedToken(2, timestampMs: 15),
        const DecodedToken(3, timestampMs: 20),
        const DecodedToken(4, timestampMs: 25),
      ]);
      // 4 distinct token IDs (0..3) are queried by
      // MapWordsToOnsetTokenIndices: <= 2 decode calls per distinct ID, each
      // with <= 3 tokens.
      expect(pieceDecodeCalls, lessThanOrEqualTo(4 * 2));
      expect(maxPieceDecodeLen, lessThanOrEqualTo(3));
      expect(words1, hasLength(3));
      expect(words1[0].text, "There's");
      expect(words1[0].timestampMs, 10);
      expect(words1[1].text, 'his');
      expect(words1[1].timestampMs, 15);
      expect(words1[2].text, 'beak');
      expect(words1[2].timestampMs, 20);

      // Second chunk reuses already-cached token pieces: 0 piece decode calls
      // and only 1 full-sequence decode call.
      final callsAfterFirstChunk = callCount;
      final pieceCallsAfterFirstChunk = pieceDecodeCalls;
      final words2 = detokenizer.detokenize([
        const DecodedToken(0, timestampMs: 110),
        const DecodedToken(1, timestampMs: 112),
        const DecodedToken(2, timestampMs: 115),
        const DecodedToken(3, timestampMs: 120),
        const DecodedToken(4, timestampMs: 125),
      ]);
      expect(pieceDecodeCalls - pieceCallsAfterFirstChunk, 0);
      expect(callCount - callsAfterFirstChunk, 1);
      expect(words2, hasLength(3));
      expect(words2[0].text, "There's");
      expect(words2[0].timestampMs, 110);
      expect(words2[1].text, 'his');
      expect(words2[1].timestampMs, 115);
      expect(words2[2].text, 'beak');
      expect(words2[2].timestampMs, 120);
    });

    test('ByteMergeTokensPreserveExactWordOnsetTimestampsAcrossChunks', () {
      // Simulate byte-level BPE (e.g. Whisper) where token 0 is a leading
      // space + UTF-8 lead byte (\xce) and token 1 is a continuation byte
      // (\xa9). Any unpaired byte renders as U+FFFD (\xef\xbf\xbd), whereas
      // the consecutive pair {0, 1} merges into " Ω" ("\xce\xa9").
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) {
          final out = <int>[];
          for (var i = 0; i < ids.length; ++i) {
            if (ids[i] == 0 && i + 1 < ids.length && ids[i + 1] == 1) {
              out.addAll([0x20, 0xce, 0xa9]);
              ++i;
            } else if (ids[i] == 0) {
              out.addAll([0x20, 0xef, 0xbf, 0xbd]);
            } else if (ids[i] == 1) {
              out.addAll([0xef, 0xbf, 0xbd]);
            } else if (ids[i] == 2) {
              out.addAll(_s(' te'));
            } else if (ids[i] == 3) {
              out.addAll(_s('st'));
            } else if (ids[i] == 4) {
              out.addAll(_s(' ca'));
            } else if (ids[i] == 5) {
              out.addAll(_s('fe'));
            } else if (ids[i] == 6) {
              out.addAll(_s(' now'));
            }
          }
          if (out.isNotEmpty && out.first == 0x20) {
            out.removeAt(0);
          }
          return out;
        };
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      // First chunk starts with the byte-merge pair {0, 1} ("Ω") followed by
      // multi-token subword {2, 3} ("test") and single-token word {6} ("now").
      final words1 = detokenizer.detokenize([
        const DecodedToken(0, timestampMs: 10),
        const DecodedToken(1, timestampMs: 12),
        const DecodedToken(2, timestampMs: 30),
        const DecodedToken(3, timestampMs: 35),
        const DecodedToken(6, timestampMs: 70),
      ]);
      expect(words1, hasLength(3));
      expect(words1[0].text, 'Ω');
      expect(words1[0].timestampMs, 10); // Token 0
      expect(words1[1].text, 'test');
      expect(words1[1].timestampMs, 30); // Token 2 (" te")
      expect(words1[2].text, 'now');
      expect(words1[2].timestampMs, 70); // Token 6 (" now")

      // Second chunk contains the byte-merge pair {0, 1} in the middle along
      // with multi-token words {2, 3, 5} ("testfe") and {4, 5} ("cafe") and
      // {6} ("now").
      final words2 = detokenizer.detokenize([
        const DecodedToken(6, timestampMs: 100),
        const DecodedToken(0, timestampMs: 110),
        const DecodedToken(1, timestampMs: 115),
        const DecodedToken(2, timestampMs: 130),
        const DecodedToken(3, timestampMs: 135),
        const DecodedToken(5, timestampMs: 140),
        const DecodedToken(4, timestampMs: 160),
        const DecodedToken(5, timestampMs: 165),
      ]);
      expect(words2, hasLength(4));
      expect(words2[0].text, 'now');
      expect(words2[0].timestampMs, 100); // Token index 0 (id 6)
      expect(words2[1].text, 'Ω');
      expect(words2[1].timestampMs, 110); // Token index 1 (id 0, not 2!)
      expect(words2[2].text, 'testfe');
      expect(words2[2].timestampMs, 130); // Token index 3 (id 2, not 5!)
      expect(words2[3].text, 'cafe');
      expect(words2[3].timestampMs, 160); // Token index 6 (id 4, not 7!)
    });

    test(
      'LeadingControlTokenPreservesExactWordOnsetTimestampsAcrossChunks',
      () {
        // Simulate SentencePiece's single-token control token quirk: token 0
        // renders as "<bos>" when decoded alone (ids.size() == 1), but as ""
        // inside any multi-token sequence (ids.size() > 1).
        const pieces = ['', ' Th', 'ere', "'s", ' a', ' way'];
        final fake = _FakeTokenizer()
          ..tokenIdsToTextFn = (ids) {
            if (ids.length == 1 && ids[0] == 0) {
              return _s('<bos>');
            }
            var out = '';
            for (final id in ids) {
              if (id > 0 && id < pieces.length) out += pieces[id];
            }
            if (out.isNotEmpty && out.startsWith(' ')) {
              out = out.substring(1);
            }
            return _s(out);
          };
        final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

        // First chunk starts with control token 0 ("<bos>").
        final words1 = detokenizer.detokenize([
          const DecodedToken(0, timestampMs: 5),
          const DecodedToken(1, timestampMs: 10),
          const DecodedToken(2, timestampMs: 15),
          const DecodedToken(3, timestampMs: 20),
          const DecodedToken(4, timestampMs: 40),
          const DecodedToken(5, timestampMs: 60),
        ]);
        expect(words1, hasLength(3));
        expect(words1[0].text, "There's");
        // Token index 1 (" Th"), skipping <bos>
        expect(words1[0].timestampMs, 10);
        expect(words1[1].text, 'a');
        expect(words1[1].timestampMs, 40); // Token index 4 (" a")
        expect(words1[2].text, 'way');
        expect(words1[2].timestampMs, 60); // Token index 5 (" way")

        // Following chunk keeps exact word-onset timestamps.
        final words2 = detokenizer.detokenize([
          const DecodedToken(1, timestampMs: 110),
          const DecodedToken(2, timestampMs: 115),
          const DecodedToken(3, timestampMs: 120),
          const DecodedToken(4, timestampMs: 140),
          const DecodedToken(5, timestampMs: 160),
        ]);
        expect(words2, hasLength(3));
        expect(words2[0].text, "There's");
        expect(words2[0].timestampMs, 110); // Token index 0 (" Th")
        expect(words2[1].text, 'a');
        expect(words2[1].timestampMs, 140); // Token index 3 (" a")
        expect(words2[2].text, 'way');
        expect(words2[2].timestampMs, 160); // Token index 4 (" way")
      },
    );

    test('ProcessTokensPicksClosestTimestampWhenTokenLacksTimestamp', () {
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) =>
            _sameIds(ids, [1, 2, 3]) ? _s('alpha beta gamma') : _s('');
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      // Token 0 at index 0 has no timestamp, Token 1 at index 1 has 200ms,
      // Token 2 at index 2 has no timestamp.
      final words = detokenizer.detokenize([
        const DecodedToken(1),
        const DecodedToken(2, timestampMs: 200),
        const DecodedToken(3),
      ]);

      expect(words, hasLength(3));
      expect(words[0].text, 'alpha');
      expect(words[0].timestampMs, 200); // Closest is token 1 (200ms)
      expect(words[1].text, 'beta');
      expect(words[1].timestampMs, 200); // Token 1 itself
      expect(words[2].text, 'gamma');
      expect(words[2].timestampMs, 200); // Closest is token 1 (200ms)
    });

    test('ProcessUntimestampedTokensSkipsPrefixDetokenization', () {
      var callCount = 0;
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) {
          ++callCount;
          return _sameIds(ids, [1, 2, 3]) ? _s('hello world') : _s('');
        };
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      final words = detokenizer.detokenize([
        const DecodedToken(1),
        const DecodedToken(2),
        const DecodedToken(3),
      ]);

      expect(callCount, 1);
      expect(words, hasLength(2));
      expect(words[0].text, 'hello');
      expect(words[0].timestampMs, isNull);
      expect(words[1].text, 'world');
      expect(words[1].timestampMs, isNull);
    });

    test('ProcessTokensWithEndOfChunkTokenAppendsEmptyWordWithTimestamp', () {
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) =>
            _sameIds(ids, [101, 102]) ? _s('hello world') : _s('');
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      final words = detokenizer.detokenize([
        const DecodedToken(101, timestampMs: 100),
        const DecodedToken(102, timestampMs: 200),
        const DecodedToken(DecodedToken.endOfChunkTokenId, timestampMs: 5000),
      ]);

      expect(words, hasLength(3));
      expect(words[0].text, 'hello');
      expect(words[0].timestampMs, 100);
      expect(words[0].isEndOfChunk, isFalse);

      expect(words[1].text, 'world');
      expect(words[1].timestampMs, 200);
      expect(words[1].isEndOfChunk, isFalse);

      expect(words[2].text, '');
      expect(words[2].timestampMs, 5000);
      expect(words[2].isEndOfChunk, isTrue);
    });

    test('CjkCharactersAreWordsWithTheirTokenTimestamps', () {
      // Token 5 and 6 split "中" (E4 B8 AD) across two tokens, as byte-level
      // BPE tokenizers do.
      final pieces = <int, List<int>>{
        1: _s('你好'),
        2: _s('吗？'),
        3: _s(' OK'),
        4: _s('世界'),
        5: [0xE4, 0xB8],
        6: [0xAD, ..._s('文')],
      };
      final fake = _FakeTokenizer()
        ..tokenIdsToTextFn = (ids) => [
          for (final id in ids)
            ...pieces[id] ?? (throw StateError('no piece for $id')),
        ];
      final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);

      final words = detokenizer.detokenize([
        const DecodedToken(1, timestampMs: 100),
        const DecodedToken(2, timestampMs: 200),
        const DecodedToken(3, timestampMs: 300),
        const DecodedToken(4, timestampMs: 400),
        const DecodedToken(5, timestampMs: 500),
        const DecodedToken(6, timestampMs: 600),
      ]);

      expect(_pairs(words), [
        ('你', 100),
        ('好', 100),
        ('吗？', 200),
        ('OK', 300),
        ('世', 400),
        ('界', 400),
        ('中', 500),
        ('文', 600),
      ]);
    });
  });

  test('a tokenizer that throws fails the window instead of being skipped', () {
    final fake = _FakeTokenizer()
      // Whole texts decode; the repeated pairs and triples the per-token
      // pieces are read from fail.
      ..tokenIdsToTextFn = (ids) => ids.length > 1 && ids.toSet().length == 1
          ? throw StateError('tokenizer broke')
          : _s([for (final id in ids) id == 1 ? 'hello' : ' world'].join());
    final detokenizer = TokenizerDetokenizer(fake.tokenIdsToUtf8);
    expect(
      () => detokenizer.detokenize([
        const DecodedToken(1, timestampMs: 100),
        const DecodedToken(2, timestampMs: 200),
        const DecodedToken.endOfChunk(timestampMs: 10),
      ]),
      throwsStateError,
    );
  });
}
