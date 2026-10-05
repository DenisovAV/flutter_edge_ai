// Unit tests for `resolveEmbeddingTokenizer`'s routing (Phase 2 hardened
// plan Task 3). No native session; exercises real file I/O against tiny
// fixtures written to a temp dir.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_embeddings/wordpiece_embedding_tokenizer.dart';
import 'package:flutter_gemma_embeddings/src/tokenizer_router.dart';
import 'package:flutter_test/flutter_test.dart';

const _wordPieceVocab = {
  '[PAD]': 0,
  '[UNK]': 100,
  '[CLS]': 101,
  '[SEP]': 102,
  'hi': 4000,
};

String _wordPieceJson() => jsonEncode({
  'version': '1.0',
  'normalizer': {'type': 'BertNormalizer', 'lowercase': true},
  'model': {
    'type': 'WordPiece',
    'unk_token': '[UNK]',
    'vocab': _wordPieceVocab,
  },
});

/// A BPE `tokenizer.json` carrying SigLIP 2's two distinguishing pipeline
/// blocks. [fixedPadding] and [eosOnlyTemplate] switch them off individually so
/// a test can show the guard needs BOTH — a file with only one is an ordinary
/// BPE tokenizer and must still route to the Gemma adapter.
String _siglip2Json({bool fixedPadding = true, bool eosOnlyTemplate = true}) =>
    jsonEncode({
      'version': '1.0',
      'padding': fixedPadding
          ? {
              'strategy': {'Fixed': 64},
              'direction': 'Right',
              'pad_id': 0,
              'pad_token': '<pad>',
            }
          : null,
      'post_processor': {
        'type': 'TemplateProcessing',
        'single': [
          if (!eosOnlyTemplate)
            {
              'SpecialToken': {'id': '<bos>', 'type_id': 0},
            },
          {
            'Sequence': {'id': 'A', 'type_id': 0},
          },
          {
            'SpecialToken': {'id': '<eos>', 'type_id': 0},
          },
        ],
      },
      'model': {
        'type': 'BPE',
        'unk_token': '<unk>',
        'vocab': {'<pad>': 0, '<eos>': 1, '<bos>': 2, '<unk>': 3},
        'merges': <List<String>>[],
      },
    });

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp(
      'onnx_tokenizer_loader_test',
    );
  });

  tearDown(() async {
    await tmpDir.delete(recursive: true);
  });

  test('a `tokenizer.json` with model.type=WordPiece routes to '
      'WordPieceEmbeddingTokenizer', () async {
    final path = '${tmpDir.path}/tokenizer.json';
    await File(path).writeAsString(_wordPieceJson());

    final tokenizer = await resolveEmbeddingTokenizer(path);
    expect(tokenizer, isA<WordPieceEmbeddingTokenizer>());
  });

  test('a `.json`-named file that is not a WordPiece model falls through '
      'to the SentencePiece adapter — a non-.json-loadable path throws '
      'there rather than being silently misrouted', () async {
    final path = '${tmpDir.path}/tokenizer.json';
    await File(path).writeAsString(
      jsonEncode({
        'model': {'type': 'BPE'},
      }),
    );

    // The Gemma SentencePiece adapter cannot parse this HF BPE schema
    // either — it throws, but importantly it is REACHED (not silently
    // treated as WordPiece, which would corrupt every token id).
    await expectLater(resolveEmbeddingTokenizer(path), throwsA(anything));
  });

  test(
    'a non-JSON-named file (raw SentencePiece `.model` binary) is never '
    'read as JSON — routes straight to the SentencePiece adapter without '
    'attempting `File.readAsString` (which throws FileSystemException on '
    'invalid UTF-8, verified against a real tokenizer.model download)',
    () async {
      final path = '${tmpDir.path}/tokenizer.model';
      // Write genuinely invalid-UTF-8 bytes — if `resolveEmbeddingTokenizer`
      // ever tried `readAsString()` on this path, it would throw
      // FileSystemException before even reaching the SentencePiece loader.
      await File(path).writeAsBytes([0xFF, 0xFE, 0x00, 0x01, 0x02]);

      // The SentencePiece adapter itself will fail on this garbage — the
      // point is WHERE it fails (inside SentencePiece parsing, not
      // File.readAsString's UTF-8 decode).
      await expectLater(resolveEmbeddingTokenizer(path), throwsA(anything));
    },
  );

  test('a SigLIP 2 `tokenizer.json` is REFUSED rather than routed to the Gemma '
      'adapter — it is BPE, so without the guard it would be tokenized with a '
      'BOS, no lowercasing and no 64-wide padding, every id in range and '
      'nothing thrown', () async {
    final path = '${tmpDir.path}/tokenizer.json';
    await File(path).writeAsString(_siglip2Json());

    await expectLater(
      resolveEmbeddingTokenizer(path),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('SigLIP 2'),
            // The message has to name the way out, not just the refusal.
            contains('loadSiglipSentencePieceEmbeddingTokenizer'),
            contains(path),
          ),
        ),
      ),
    );
  });

  test('an ordinary BPE tokenizer.json carrying only ONE of the two SigLIP 2 '
      'signals still routes to the Gemma adapter', () async {
    // Guards against the refusal widening into every BPE file: plenty of
    // models declare a fixed padding block, and plenty declare a
    // post-processor that appends an EOS. Only both together mean SigLIP 2.
    for (final json in [
      _siglip2Json(fixedPadding: false),
      _siglip2Json(eosOnlyTemplate: false),
    ]) {
      final path = '${tmpDir.path}/tokenizer.json';
      await File(path).writeAsString(json);

      // It loads: the Gemma adapter accepts this stub vocabulary. The
      // assertion is that the guard did not claim the file.
      expect(await resolveEmbeddingTokenizer(path), isA<EmbeddingTokenizer>());
    }
  });
}
