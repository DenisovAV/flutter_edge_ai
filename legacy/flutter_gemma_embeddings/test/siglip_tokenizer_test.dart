// Unit tests for the SigLIP2 SentencePiece embedding-tokenizer adapter
// (`loadSiglipSentencePieceEmbeddingTokenizer` / `encodeForSiglipEmbedding`).
//
// SigLIP2's text tower uses a DIFFERENT convention from Gemma: NO leading BOS,
// a SINGLE trailing EOS, lowercased text, and a FIXED 64-token width (its ONNX
// export reads as dynamic-shape and carries no attention_mask, so the padding
// must live in the token ids). These tests pin that convention using a tiny,
// self-contained tokenizer — no multi-MB model checked in.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma_embeddings/src/embedding_tokenizer.dart';
import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes a tiny SentencePiece tokenizer (single-char vocab over [alphabet])
/// in the library's own JSON format.
///
/// The special ids deliberately mirror the REAL SigLIP 2 vocabulary — the Gemma
/// BPE one — rather than a generic T5 layout: `<pad>`=0, `<eos>`=1, `<bos>`=2,
/// `<unk>`=3, alphabet from 4. `loadSiglipSentencePieceEmbeddingTokenizer`
/// rejects anything else, and a fixture that did not match would have tested a
/// vocabulary no SigLIP model ships. Normalizer flags are all off so
/// tokenization is exact.
Future<String> _writeTinyTokenizer(
  Directory dir,
  String alphabet, {
  bool siglip1Layout = false,
}) async {
  // `siglip1Layout` builds the OTHER convention — T5 Unigram-style, as SigLIP 1
  // ships it — so a test can prove the loader refuses it instead of quietly
  // embedding with the wrong pad id.
  final pieces = siglip1Layout
      ? ['<unk>', '</s>', '<s>', '<pad>', ...alphabet.split('')]
      : ['<pad>', '<eos>', '<bos>', '<unk>', ...alphabet.split('')];
  final types = siglip1Layout
      ? [2, 3, 3, 3, ...List.filled(alphabet.length, 1)]
      : [3, 3, 3, 2, ...List.filled(alphabet.length, 1)];
  final json = {
    'version': '1.0',
    'model_type': 'bpe',
    'vocab': {
      'pieces': pieces,
      'scores': List.filled(pieces.length, 0.0),
      'types': types,
    },
    'special_tokens': siglip1Layout
        ? {
            'unk': {'id': 0, 'piece': '<unk>'},
            'eos': {'id': 1, 'piece': '</s>'},
            'bos': {'id': 2, 'piece': '<s>'},
            'pad': {'id': 3, 'piece': '<pad>'},
          }
        : {
            'pad': {'id': 0, 'piece': '<pad>'},
            'eos': {'id': 1, 'piece': '<eos>'},
            'bos': {'id': 2, 'piece': '<bos>'},
            'unk': {'id': 3, 'piece': '<unk>'},
          },
    'normalizer': {
      'add_dummy_prefix': false,
      'remove_extra_whitespaces': false,
      'escape_whitespaces': false,
    },
    'config': {'add_bos_token': false, 'add_eos_token': false},
    'byte_fallback': false,
  };
  // Distinct names per layout: both fixtures share `tmpDir`, and a single name
  // meant the SigLIP-1 variant overwrote the file the suite loaded in setUpAll.
  final name = siglip1Layout ? 'tiny_siglip1.json' : 'tiny_tokenizer.json';
  final file = File('${dir.path}/$name');
  await file.writeAsString(jsonEncode(json));
  return file.path;
}

void main() {
  late Directory tmpDir;
  late EmbeddingTokenizer siglip;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('siglip_tokenizer_test');
    // alphabet 'ab' -> ids: a=4, b=5.
    final path = await _writeTinyTokenizer(tmpDir, 'ab');
    siglip = await loadSiglipSentencePieceEmbeddingTokenizer(path);
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  group('SigLIP tokenizer convention', () {
    test('no BOS, single trailing EOS, right-padded to the fixed width', () {
      final ids = siglip.encode('', 'ab').ids;

      expect(ids.length, siglipSeqLen);
      // Content starts immediately — NO BOS is prepended.
      expect(ids[0], 4); // 'a'
      expect(ids[1], 5); // 'b'
      // A single EOS follows the content...
      expect(ids[2], siglipEosId);
      // ...then pad to the fixed width.
      expect(ids.sublist(3).every((id) => id == siglipPadId), isTrue);
    });

    test('lowercases the input before tokenizing', () {
      expect(siglip.encode('', 'AB').ids, siglip.encode('', 'ab').ids);
    });

    test('the TaskType prefix is DROPPED, not embedded as leading text', () {
      // Every production call arrives with one: CommonEmbeddingModel passes
      // `taskType.prefix`, and generateEmbedding DEFAULTS to
      // TaskType.retrievalQuery — no caller can pass an empty prefix. An
      // earlier revision concatenated it (and a test pinned that as the
      // contract), so every SigLIP vector was the embedding of
      // "task: search result | query: " + text: shifted off the space the
      // vision tower shares, and different for query vs document of one string.
      const query = 'task: search result | query: ';
      const document = 'title: none | text: ';
      final bare = siglip.encode('', 'ab').ids;

      expect(siglip.encode(query, 'ab').ids, bare);
      expect(siglip.encode(document, 'ab').ids, bare);
    });

    test('reports the pad tail in the attention mask', () {
      // The adapter builds the padding itself, so it is the only thing that
      // knows which positions are real. With a null mask the ONNX forward pass
      // fabricates an all-ones one over the pad tail.
      final out = siglip.encode('', 'ab');

      expect(out.attentionMask, isNotNull);
      expect(out.attentionMask!.length, siglipSeqLen);
      // 'a', 'b', EOS are real; the remaining 61 positions are padding.
      expect(out.attentionMask!.sublist(0, 3), everyElement(1));
      expect(out.attentionMask!.sublist(3), everyElement(0));
    });

    test('a full-width input reports an all-real mask', () {
      // The boundary the trailing-pad count has to get right: no padding at all.
      final out = siglip.encode('', 'a' * 63);

      expect(out.attentionMask!.length, siglipSeqLen);
      expect(out.attentionMask, everyElement(1));
    });

    // The three boundary cases, against the reference (`tokenizers` with
    // `enable_truncation(64)` plus the json's own fixed-64 right-padding, which
    // is also what DJL's LONGEST_FIRST default produces):
    //
    //   62 content -> [62 content, EOS, pad]
    //   63 content -> [63 content, EOS]        (no padding left)
    //   64+        -> [first 63,   EOS]        (EOS SURVIVES truncation)
    //
    // An earlier revision appended the EOS and then cut back to 64, dropping it
    // on the third case — cosine 0.9683 against a correct vector.

    test('content just under the width keeps EOS and pads', () {
      final ids = siglip.encode('', 'a' * 62).ids;
      expect(ids.length, siglipSeqLen);
      expect(ids.sublist(0, 62).every((id) => id == 4), isTrue);
      expect(ids[62], siglipEosId);
      expect(ids[63], siglipPadId);
    });

    test('content exactly filling the width leaves no padding', () {
      final ids = siglip.encode('', 'a' * 63).ids;
      expect(ids.length, siglipSeqLen);
      expect(ids.sublist(0, 63).every((id) => id == 4), isTrue);
      expect(ids[63], siglipEosId);
      expect(ids.contains(siglipPadId), isFalse);
    });

    test(
      'a SigLIP 1 vocabulary is refused instead of embedded wrongly',
      () async {
        // SigLIP 1's ids stay in range, so nothing throws downstream — the only
        // symptom would be degraded retrieval. Since the model pools the LAST
        // position, its pad id (`</s>` = 1, not `<pad>` = 0) lands straight in
        // the pooled vector.
        final path = await _writeTinyTokenizer(
          tmpDir,
          'ab',
          siglip1Layout: true,
        );
        await expectLater(
          loadSiglipSentencePieceEmbeddingTokenizer(path),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              contains('not a SigLIP 2 tokenizer'),
            ),
          ),
        );
      },
    );

    test('truncation keeps the trailing EOS rather than cutting it off', () {
      final ids = siglip.encode('', 'a' * 200).ids;
      expect(ids.length, siglipSeqLen);
      expect(
        ids.sublist(0, siglipSeqLen - 1).every((id) => id == 4),
        isTrue,
        reason: 'the first 63 positions are content',
      );
      expect(
        ids[siglipSeqLen - 1],
        siglipEosId,
        reason:
            'the reference truncates content to 63 and keeps <eos> last; '
            'appending EOS and then clamping to 64 would drop it here',
      );
    });
  });
}
