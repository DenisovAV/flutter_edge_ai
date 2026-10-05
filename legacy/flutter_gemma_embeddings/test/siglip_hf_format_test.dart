@TestOn('vm')
library;

// The other SigLIP test builds its tokenizer in the LIBRARY's own JSON format.
// Real models do not ship that — they ship HuggingFace `tokenizer.json`, and the
// difference is not cosmetic: the HF path parses `pre_tokenizer`,
// `post_processor`, list-form `merges` and `added_tokens`, none of which the
// internal format exercises.
//
// That gap hid a real break. `dart_sentencepiece_tokenizer` 1.3.3 loads SigLIP2's
// file; 1.4.0 added `pre_tokenizer` validation with no `Split` case and rejects
// it, so `^1.3.3` resolved to 1.4.0 and the profile threw
// `Unsupported Hugging Face pre-tokenizer: Split` for anyone installing from
// pub.dev. Nothing in the suite noticed, because nothing here had ever fed the
// loader a HuggingFace file.
//
// This fixture is that file in miniature: same `model.type`, same `Split`
// pre-tokenizer (`pattern: {String: " "}`, `MergedWithPrevious`), same list-form
// `merges` and `added_tokens`, with an eight-token vocabulary instead of 256k.
// Its `post_processor` and `padding` blocks mirror the real file for fidelity.
// On 1.4.1 the dependency DOES apply `padding` at load; `loadEmbeddingTokenizer`
// then switches it back off. `post_processor` is parsed but its result is
// discarded, because the explicit `SentencePieceConfig` wins. See the test body.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma_embeddings/src/embedding_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// A HuggingFace `tokenizer.json` carrying SigLIP2's pipeline blocks verbatim.
Future<String> _writeHfTokenizer(Directory dir) async {
  const vocab = {
    '<pad>': 0,
    '<eos>': 1,
    '<bos>': 2,
    '<unk>': 3,
    '▁a': 4,
    '▁b': 5,
    'a': 6,
    'b': 7,
  };
  final json = {
    'version': '1.0',
    'truncation': null,
    // Verbatim from SigLIP2's tokenizer.json.
    'padding': {
      'strategy': {'Fixed': 64},
      'direction': 'Right',
      'pad_to_multiple_of': null,
      'pad_id': 0,
      'pad_type_id': 0,
      'pad_token': '<pad>',
    },
    'added_tokens': [
      for (final e in const [
        ('<pad>', 0),
        ('<eos>', 1),
        ('<bos>', 2),
        ('<unk>', 3),
      ])
        {
          'id': e.$2,
          'content': e.$1,
          'single_word': false,
          'lstrip': false,
          'rstrip': false,
          'normalized': false,
          'special': true,
        },
    ],
    // Verbatim from SigLIP2's and EmbeddingGemma's tokenizer.json, and
    // load-bearing since 1.4.1: the loader accepts the `Split` below only
    // because this Replace proves no literal space can reach it.
    'normalizer': {
      'type': 'Replace',
      'pattern': {'String': ' '},
      'content': '\u2581',
    },
    // The block 1.4.0 rejects.
    'pre_tokenizer': {
      'type': 'Split',
      'pattern': {'String': ' '},
      'behavior': 'MergedWithPrevious',
      'invert': false,
    },
    // No BOS — the half that distinguishes SigLIP2 from a Gemma tokenizer.
    'post_processor': {
      'type': 'TemplateProcessing',
      'single': [
        {
          'Sequence': {'id': 'A', 'type_id': 0},
        },
        {
          'SpecialToken': {'id': '<eos>', 'type_id': 0},
        },
      ],
      'pair': [
        {
          'Sequence': {'id': 'A', 'type_id': 0},
        },
      ],
      'special_tokens': {
        '<eos>': {
          'id': '<eos>',
          'ids': [1],
          'tokens': ['<eos>'],
        },
      },
    },
    'decoder': null,
    'model': {
      'type': 'BPE',
      'unk_token': '<unk>',
      'vocab': vocab,
      // List-of-pairs form — what upstream #26 taught 1.3.3 to read.
      'merges': [
        ['a', 'b'],
      ],
    },
  };
  final path = '${dir.path}/tokenizer.json';
  await File(path).writeAsString(jsonEncode(json));
  return path;
}

/// The same miniature file in Gemma's convention — BOS-first post-processor —
/// but carrying a `padding` block, which no shipped EmbeddingGemma export does.
/// That is the point: the Gemma path must not depend on the file not having one.
Future<String> _writeGemmaHfTokenizer(Directory dir) async {
  const vocab = {
    '<pad>': 0,
    '<eos>': 1,
    '<bos>': 2,
    '<unk>': 3,
    '\u2581a': 4,
    '\u2581b': 5,
  };
  final json = {
    'version': '1.0',
    'truncation': null,
    'padding': {
      'strategy': {'Fixed': 16},
      'direction': 'Right',
      'pad_to_multiple_of': null,
      'pad_id': 0,
      'pad_type_id': 0,
      'pad_token': '<pad>',
    },
    'added_tokens': [
      for (final e in const [
        ('<pad>', 0),
        ('<eos>', 1),
        ('<bos>', 2),
        ('<unk>', 3),
      ])
        {
          'id': e.$2,
          'content': e.$1,
          'single_word': false,
          'lstrip': false,
          'rstrip': false,
          'normalized': false,
          'special': true,
        },
    ],
    'normalizer': {
      'type': 'Replace',
      'pattern': {'String': ' '},
      'content': '\u2581',
    },
    'pre_tokenizer': null,
    // The BOS-prepending template real EmbeddingGemma exports ship — and what
    // `isSiglip2TokenizerJson` keys on to tell Gemma from SigLIP 2. It must stay
    // suppressed by the explicit SentencePieceConfig: `encodeForEmbedding` adds
    // its own BOS, so honouring this too would give [BOS, BOS, …] silently.
    'post_processor': {
      'type': 'TemplateProcessing',
      'single': [
        {
          'SpecialToken': {'id': '<bos>', 'type_id': 0},
        },
        {
          'Sequence': {'id': 'A', 'type_id': 0},
        },
      ],
      'pair': [
        {
          'Sequence': {'id': 'A', 'type_id': 0},
        },
      ],
      'special_tokens': {
        '<bos>': {
          'id': '<bos>',
          'ids': [2],
          'tokens': ['<bos>'],
        },
      },
    },
    'decoder': null,
    'model': {
      'type': 'BPE',
      'unk_token': '<unk>',
      'vocab': vocab,
      'merges': <List<String>>[],
    },
  };
  final path = '${dir.path}/gemma_tokenizer.json';
  await File(path).writeAsString(jsonEncode(json));
  return path;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('siglip_hf_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the SigLIP2 profile loads a HuggingFace-format tokenizer.json', () async {
    final path = await _writeHfTokenizer(dir);

    // The first assertion is that this does not throw: a dependency that
    // rejects the `Split` pre-tokenizer or the list-form `merges` fails right
    // here, which is what a version range admitting such a release would
    // otherwise ship to users unnoticed.
    final tok = await loadSiglipSentencePieceEmbeddingTokenizer(path);

    // Then a canary on the result: the two pieces, the EOS, then padding — and
    // no BOS (id 2), which is the Gemma convention rather than SigLIP2's.
    //
    // `a`(6) and not `▁a`(4): the real files carry a BARE Replace with no
    // Prepend, so nothing marks the first piece, and only the space becomes
    // U+2581. A fixture with `normalizer: null` got a dummy prefix instead and
    // did not reproduce the file it stands for.
    final ids = tok.encode('', 'a b').ids;
    expect(ids.take(3), [6, 5, siglipEosId]);
    expect(ids.skip(3), everyElement(siglipPadId));

    // What this fixture does and does not exercise, established by mutating it.
    // The `pre_tokenizer` is inert: 1.3.3 had no parsing for it, and 1.4.1
    // accepts this `Split` only because the normalizer above proves no literal
    // space reaches it. The `post_processor` is inert too — `loadEmbeddingTokenizer`
    // passes an explicit `SentencePieceConfig`, and every loader version takes
    // the caller's config over the file's. The `padding` block is NOT inert on
    // 1.4.1 — it is applied at load — but `loadEmbeddingTokenizer` turns it back
    // off with `noPadding()`, so `encode()` hands this profile bare content and
    // the width rule below is the only one that applies. Nothing reduces
    // anything downstream, so do not go looking for stripping code.
    //
    // So the LOAD is the load-bearing assertion here, and what it guards is
    // exactly the version range: 1.3.2 cannot read the list-form `merges`,
    // 1.4.0 rejects the `Split` block.
  });

  test(
    'the Gemma path survives a tokenizer.json that declares padding',
    () async {
      // No shipped EmbeddingGemma export declares one — `padding` is null in
      // `onnx-community/embeddinggemma-300m-ONNX`. But on 1.4.1 the loader
      // applies the block when it IS there, and `encodeForEmbedding` appends its
      // EOS after whatever `encode()` returned. Unless the loader turns the
      // block off that gives `[BOS, content, pad…, EOS]`: the EOS stranded past
      // the pad run, every vector shifted, nothing thrown.
      final tok = await loadGemmaSentencePieceEmbeddingTokenizer(
        await _writeGemmaHfTokenizer(dir),
      );

      final ids = tok.encode('', 'a b').ids;

      // One exact list, not three separate checks. `encodeForEmbedding` returns
      // `[bosId, ...encode(), eosId]`, so `ids.first == bosId` and
      // `ids.last == eosId` are true by construction — they held even for
      // `[BOS, content, pad…, EOS]`, the very shape they claimed to rule out.
      // Pinning the whole list makes right-padding, left-padding, truncation, a
      // stranded EOS and a doubled BOS all fail here.
      //
      // `3` is `<unk>`: this fixture's vocab has `▁a`/`▁b` but no bare `a`, and
      // the bare Replace normalizer adds no leading marker, so `a b` is
      // `a` + `▁b` -> unk, 5.
      expect(ids, [bosId, 3, 5, eosId]);
    },
  );
}
