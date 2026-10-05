// Unit tests for `parseWordPieceTokenizerJson` — pure Dart, no
// `dart:js_interop`, runs under plain `flutter test` (VM).

import 'dart:convert';

import 'package:flutter_gemma_embeddings/wordpiece_embedding_tokenizer.dart';
import 'package:flutter_gemma_embeddings/src/wordpiece_tokenizer_json.dart';
import 'package:flutter_test/flutter_test.dart';

String _wordPieceJson() {
  return jsonEncode({
    'model': {
      'type': 'WordPiece',
      'unk_token': '[UNK]',
      'continuing_subword_prefix': '##',
      'max_input_chars_per_word': 100,
      'vocab': {'[UNK]': 100, '[CLS]': 101, '[SEP]': 102, 'hello': 7592},
    },
  });
}

String _bpeJson() {
  return jsonEncode({
    'model': {'type': 'BPE', 'vocab': <String, int>{}, 'merges': <String>[]},
  });
}

void main() {
  group('parseWordPieceTokenizerJson', () {
    test(
      'routes a WordPiece tokenizer.json to WordPieceEmbeddingTokenizer',
      () {
        final tokenizer = parseWordPieceTokenizerJson(_wordPieceJson());
        expect(tokenizer, isA<WordPieceEmbeddingTokenizer>());
      },
    );

    test('a WordPiece tokenizer tokenizes correctly through the seam', () {
      final tokenizer = parseWordPieceTokenizerJson(_wordPieceJson());
      final result = tokenizer.encode('', 'hello');
      expect(result.ids, [101, 7592, 102]);
    });

    test('throws UnsupportedError for a non-WordPiece tokenizer.json (BPE — '
        'SentencePiece/EmbeddingGemma-family is not supported on web)', () {
      expect(
        () => parseWordPieceTokenizerJson(_bpeJson()),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('throws FormatException for invalid JSON', () {
      expect(
        () => parseWordPieceTokenizerJson('not json'),
        throwsFormatException,
      );
    });
  });
}
