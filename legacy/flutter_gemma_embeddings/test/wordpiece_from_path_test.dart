@TestOn('vm')
library;

// `WordPieceEmbeddingTokenizer.fromPath` shipped in published 2.0.0, then
// vanished from `main` two days later as collateral of the ONNX web arm (#449):
// its `File` read needs `dart:io`, and an unconditional `dart:io` import makes
// the whole library uncompilable for web — which that PR needed, because its web
// embedding arm imports this file directly. The method came back through a
// `if (dart.library.io)` seam, so both hold at once.
//
// This test exists so the method cannot disappear silently again: deleting it
// (or the seam) fails here rather than only surfacing as a broken build in
// somebody else's app.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma_embeddings/src/wordpiece_embedding_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

String _fixtureJson() => jsonEncode({
  'model': {
    'type': 'WordPiece',
    'unk_token': '[UNK]',
    'continuing_subword_prefix': '##',
    'vocab': {
      '[PAD]': 0,
      '[UNK]': 100,
      '[CLS]': 101,
      '[SEP]': 102,
      'hello': 7592,
      'world': 2088,
    },
  },
});

void main() {
  group('WordPieceEmbeddingTokenizer.fromPath', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('wp_frompath_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('loads a tokenizer.json off disk, matching fromJsonString', () async {
      final path = '${dir.path}/tokenizer.json';
      File(path).writeAsStringSync(_fixtureJson());

      final fromDisk = await WordPieceEmbeddingTokenizer.fromPath(path);
      final fromString = WordPieceEmbeddingTokenizer.fromJsonString(
        _fixtureJson(),
      );

      expect(
        fromDisk.encode('', 'hello world').ids,
        fromString.encode('', 'hello world').ids,
        reason:
            'the path loader must produce the same tokenizer as the string '
            'loader it delegates to',
      );
    });

    test(
      'propagates a read failure instead of returning an empty tokenizer',
      () {
        expect(
          () =>
              WordPieceEmbeddingTokenizer.fromPath('${dir.path}/missing.json'),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test('propagates a FormatException for a non-WordPiece model', () async {
      final path = '${dir.path}/bad.json';
      File(path).writeAsStringSync(
        jsonEncode({
          'model': {'type': 'BPE'},
        }),
      );

      expect(
        () => WordPieceEmbeddingTokenizer.fromPath(path),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
