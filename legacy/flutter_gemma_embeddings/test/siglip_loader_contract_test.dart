@TestOn('vm')
library;

// Pins what the DEPENDENCY hands back, not what the profile produces.
//
// The profile is deliberately version-insensitive — `loadEmbeddingTokenizer`
// calls `noPadding()`/`noTruncation()`, so `encodeForSiglipEmbedding` sees bare
// content whatever the file declares. That is the right design, and it is why
// the profile cannot be the canary for a CHANGED contract: it would keep
// passing while the loader changed underneath it.
//
// (For a BROKEN contract the profile tests do now fail, because
// `requireBareContent` throws at load. That covers the shape where the disable
// calls stop clearing what they name — not the shape below, where a future
// release pads through some other field and both getters stay null.)
//
// This is the canary. 1.4.1 changed `encode()`'s return shape in a PATCH release
// — it began honouring `strategy: {Fixed: N}`, which 1.4.0 had read from a
// `length` key HuggingFace does not write — and upstream's changelog does not
// mention it. The constraint is open-topped, so the next release can do it
// again. These assertions turn that into a red build instead of a quietly
// different vector.

import 'dart:convert';
import 'dart:io';

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter_gemma_embeddings/src/embedding_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// A miniature file carrying the blocks the real SigLIP 2 tokenizer declares —
/// fixed-width right padding, and the normalizer that makes its `Split` legal —
/// plus a `truncation` block it does not (see below for why).
Future<String> _write(Directory dir) async {
  final json = {
    'version': '1.0',
    // A truncation block, so `noTruncation()` has something to undo. Real
    // SigLIP 2 and EmbeddingGemma exports declare `null` here — this is the
    // shape a future export could ship. `max_length` is a real HuggingFace key,
    // so unlike the padding width it has been honoured since 1.4.0. It must be
    // positive or the loader throws.
    'truncation': {
      'max_length': 8,
      'direction': 'Right',
      'strategy': 'LongestFirst',
      'stride': 0,
    },
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
    'normalizer': {
      'type': 'Replace',
      'pattern': {'String': ' '},
      'content': '▁',
    },
    'pre_tokenizer': {
      'type': 'Split',
      'pattern': {'String': ' '},
      'behavior': 'MergedWithPrevious',
      'invert': false,
    },
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
      // Contiguous ids: a gap makes the vocabulary build with holes and every
      // piece past it resolve to <unk>.
      'vocab': {
        '<pad>': 0,
        '<eos>': 1,
        '<bos>': 2,
        '<unk>': 3,
        '▁a': 4,
        '▁b': 5,
        'a': 6,
      },
      'merges': <List<String>>[],
    },
  };
  final path = '${dir.path}/tokenizer.json';
  await File(path).writeAsString(jsonEncode(json));
  return path;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('sp_contract_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'the fixture is live: the dependency really applies these blocks',
    () async {
      // Everything below asserts that the loader UNDOES something. If the file
      // stopped declaring anything the dependency acts on — a typo like
      // `paddding`, a lowercase `fixed` (the parser is case-sensitive), or a
      // future release tightening the parse — those assertions would all still
      // pass, on a fixture that proves nothing. The canary would be dead and
      // green. So check the precondition directly, through the raw dependency.
      final raw = await TokenizerJsonLoader.fromJsonFile(
        await _write(dir),
        config: const SentencePieceConfig(),
      );

      expect(
        raw.padding,
        isNotNull,
        reason: 'the fixture must declare padding the loader has to switch off',
      );
      // Binds the two magic numbers together. Raising `max_length` above the 20
      // used below is otherwise a silent deletion of the only coverage
      // `noTruncation()` has: the mutation stops being caught and nothing says so.
      expect(
        raw.truncation?.maxLength,
        8,
        reason: 'must stay below the 20-token input the truncation test uses',
      );
      expect(
        raw.encode('a' * 20).ids.length,
        64,
        reason: 'truncated to 8, then padded to 64 — both blocks are applied',
      );
    },
  );

  test(
    'loadEmbeddingTokenizer returns bare content, whatever the file asks for',
    () async {
      final tokenizer = await loadEmbeddingTokenizer(await _write(dir));

      final ids = tokenizer.encode('a b').ids;

      // The file declares Fixed-64 right padding. If this comes back 64 long, the
      // loader applied it and `noPadding()` stopped working — every profile that
      // appends its own terminator would put it past the pad run.
      expect(
        ids.length,
        2,
        reason:
            'the file asks for 64-wide padding; the loader must not apply it',
      );
      expect(ids, [
        6,
        5,
      ], reason: 'bare Replace normalizer, so no dummy prefix');

      // The file's post_processor appends <eos>. The explicit SentencePieceConfig
      // must keep overriding it: both profiles add their own terminator, and a
      // second one would double it.
      expect(
        ids.contains(siglipEosId),
        isFalse,
        reason:
            'the post_processor EOS must stay suppressed by the explicit config',
      );
    },
  );

  test('a long input is neither truncated nor padded by the loader', () async {
    final tokenizer = await loadEmbeddingTokenizer(await _write(dir));

    // Exactly 20, not `greaterThan(64)`. The looser assertion could not fail:
    // `withPadding` never shrinks, so a 100-token input stayed over 64 with the
    // file's padding fully applied, and `noTruncation()` had no coverage at all
    // — deleting both cascades left the whole suite green. Measured.
    //
    // 20 content tokens against a declared `max_length: 8` and `Fixed: 64`
    // padding: the loader must hand back all 20. Truncating gives 8, padding
    // gives 64, and either is a silently different vector, since the width rule
    // belongs to encodeForSiglipEmbedding and the forward pass, not here.
    final ids = tokenizer.encode('a' * 20).ids;

    expect(
      ids.length,
      20,
      reason:
          'neither the declared truncation (8) nor the padding (64) applies',
    );
  });
}
