// Golden-vector test for `WordPieceEmbeddingTokenizer` (Phase 2 — plain-ORT
// embedding forward pass, design D-T1 — the WordPiece adapter port).
//
// Vocab ids match the real `bert-base-uncased` / all-MiniLM vocab so the
// expected token-id sequences below are ground truth, captured from the
// reference HuggingFace `tokenizers` library:
//
//   'hello world'                              -> [101, 7592, 2088, 102]
//   'reddish'                                  -> [101, 14182, 102]   (single piece)
//   'redfish' (## split using red + ##fish)    -> [101, 2417, 7529, 102]
//   'Café' (accent strip + lowercase)          -> [101, 7668, 102]    (cafe)
//   'don't!' (punctuation isolation)           -> [101, 2123, 1005, 1056, 999, 102]
//   'zzqx' (unknown word)                      -> [101, 100, 102]     ([UNK])
//   '中文' (CJK — each char isolated, unknown)  -> [101, 100, 100, 102]
//
// The fixture only contains the pieces needed by these assertions.

import 'dart:convert';

import 'package:flutter_gemma_embeddings/src/wordpiece_embedding_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

const Map<String, int> _vocab = {
  '[PAD]': 0,
  '[UNK]': 100,
  '[CLS]': 101,
  '[SEP]': 102,
  'hello': 7592,
  'world': 2088,
  'reddish': 14182,
  'red': 2417,
  '##fish': 7529,
  'cafe': 7668,
  'don': 2123,
  "'": 1005,
  't': 1056,
  '!': 999,
};

String _fixtureJson({bool lowercase = true, dynamic stripAccents}) {
  return jsonEncode({
    'version': '1.0',
    'normalizer': {
      'type': 'BertNormalizer',
      'clean_text': true,
      'handle_chinese_chars': true,
      'strip_accents': stripAccents,
      'lowercase': lowercase,
    },
    'pre_tokenizer': {'type': 'BertPreTokenizer'},
    'post_processor': {
      'type': 'TemplateProcessing',
      'special_tokens': {
        '[CLS]': {
          'id': '[CLS]',
          'ids': [101],
          'tokens': ['[CLS]'],
        },
        '[SEP]': {
          'id': '[SEP]',
          'ids': [102],
          'tokens': ['[SEP]'],
        },
      },
    },
    'model': {
      'type': 'WordPiece',
      'unk_token': '[UNK]',
      'continuing_subword_prefix': '##',
      'max_input_chars_per_word': 100,
      'vocab': _vocab,
    },
  });
}

void main() {
  group('WordPieceEmbeddingTokenizer', () {
    late WordPieceEmbeddingTokenizer tokenizer;

    setUp(() {
      tokenizer = WordPieceEmbeddingTokenizer.fromJsonString(_fixtureJson());
    });

    test('isWordPieceJson identifies a WordPiece model', () {
      final json = jsonDecode(_fixtureJson()) as Map<String, dynamic>;
      expect(WordPieceEmbeddingTokenizer.isWordPieceJson(json), isTrue);
    });

    test('isWordPieceJson rejects a non-WordPiece model', () {
      final json = {
        'model': {'type': 'Unigram'},
      };
      expect(WordPieceEmbeddingTokenizer.isWordPieceJson(json), isFalse);
    });

    test('fromJsonString throws on a non-WordPiece model', () {
      expect(
        () => WordPieceEmbeddingTokenizer.fromJsonString(
          jsonEncode({
            'model': {'type': 'Unigram'},
          }),
        ),
        throwsFormatException,
      );
    });

    test('exposes canonical BERT special-token ids', () {
      expect(tokenizer.clsId, 101);
      expect(tokenizer.sepId, 102);
      expect(tokenizer.unkId, 100);
    });

    test(
      'wraps output with [CLS] … [SEP], prefix concatenated before text',
      () {
        final result = tokenizer.encode('', 'hello world');
        expect(result.ids.first, 101);
        expect(result.ids.last, 102);
        expect(result.ids, [101, 7592, 2088, 102]);
      },
    );

    test('prefix is concatenated before text (matches the SentencePiece '
        'adapter\'s convention)', () {
      // prefix 'hello ' + text 'world' == the same input as encode('',
      // 'hello world').
      expect(tokenizer.encode('hello ', 'world').ids, [101, 7592, 2088, 102]);
    });

    test('lowercases input before vocab lookup', () {
      // 'Hello WORLD' must map to the same ids as 'hello world'.
      expect(tokenizer.encode('', 'Hello WORLD').ids, [101, 7592, 2088, 102]);
    });

    test('matches a whole word that exists in the vocab (no ## split)', () {
      expect(tokenizer.encode('', 'reddish').ids, [101, 14182, 102]);
    });

    test('greedy longest-match splits into ## continuation pieces', () {
      // 'redfish' is not a vocab entry; greedy match yields red + ##fish.
      expect(tokenizer.encode('', 'redfish').ids, [101, 2417, 7529, 102]);
    });

    test('strips accents (strip_accents follows lowercase=true)', () {
      // 'Café' -> normalize -> 'cafe' -> id 7668.
      expect(tokenizer.encode('', 'Café').ids, [101, 7668, 102]);
    });

    test('isolates punctuation into separate tokens', () {
      // "don't!" -> don ' t ! -> [101, 2123, 1005, 1056, 999, 102]
      expect(tokenizer.encode('', "don't!").ids, [
        101,
        2123,
        1005,
        1056,
        999,
        102,
      ]);
    });

    test('maps an unknown word to a single [UNK]', () {
      expect(tokenizer.encode('', 'zzqx').ids, [101, 100, 102]);
    });

    test('isolates CJK characters, each becoming its own (unknown) token', () {
      // '中文' -> handle_chinese_chars surrounds each char with spaces ->
      // two separate pre-tokens -> neither is in the fixture vocab -> [UNK]
      // each.
      expect(tokenizer.encode('', '中文').ids, [101, 100, 100, 102]);
    });

    test('collapses runs of whitespace', () {
      expect(tokenizer.encode('', 'hello   world').ids, [101, 7592, 2088, 102]);
    });

    test('encodes empty string to just [CLS] [SEP]', () {
      expect(tokenizer.encode('', '').ids, [101, 102]);
    });

    test('attentionMask is all-ones, tokenTypeIds is all-zeros, both aligned '
        'to ids.length (single-segment WordPiece convention)', () {
      final result = tokenizer.encode('', 'hello world');
      expect(result.attentionMask, List.filled(result.ids.length, 1));
      expect(result.tokenTypeIds, List.filled(result.ids.length, 0));
    });
  });
}
