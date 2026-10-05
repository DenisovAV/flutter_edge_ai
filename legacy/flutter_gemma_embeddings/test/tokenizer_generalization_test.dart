// Byte-identity guard for the Gemma SentencePiece [EmbeddingTokenizer]
// adapter (Phase 2 — plain-ORT embedding forward pass, design D-T1).
//
// `loadGemmaSentencePieceEmbeddingTokenizer` must produce EXACTLY the same
// token ids as the pre-generalization call shape
// (`loadEmbeddingTokenizer` + `encodeForEmbedding`) — the LiteRT embedding
// path must stay byte-identical across this refactor (Phase 2's hard rule
// #2). This is not just an implementation detail: a silent BOS/EOS or
// prefix-order drift here would change every LiteRT embedding vector
// without throwing.
//
// Uses the local gitignored tokenizer asset at
// `packages/flutter_gemma/example/assets/test/sentencepiece.model` (see
// project memory `project_embedding_test_asset` for why it's gitignored and
// how it gets there) — skipped entirely when absent so this test never
// blocks CI/a fresh checkout on a multi-MB binary that isn't committed.

import 'dart:io';

import 'package:flutter_gemma_embeddings/src/embedding_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Relative to this package's root (`flutter test`'s cwd):
/// `packages/flutter_gemma_embeddings/` -> `../flutter_gemma/example/assets/test/sentencepiece.model`.
const _tokenizerPath =
    '../flutter_gemma/example/assets/test/sentencepiece.model';

void main() {
  final tokenizerFile = File(_tokenizerPath);

  group(
    'Gemma SentencePiece EmbeddingTokenizer byte-identity (design D-T1)',
    () {
      test(
        'adapter.encode(prefix, text).ids deep-equals the legacy '
        'encodeForEmbedding(...) call shape, across a prefix/text matrix',
        () async {
          if (!tokenizerFile.existsSync()) {
            markTestSkipped(
              'No local tokenizer asset at $_tokenizerPath — see project '
              'memory project_embedding_test_asset for how to place it '
              'locally. Skipping (not committed: multi-MB binary).',
            );
            return;
          }

          final legacyTokenizer = await loadEmbeddingTokenizer(
            tokenizerFile.path,
          );
          final adapter = await loadGemmaSentencePieceEmbeddingTokenizer(
            tokenizerFile.path,
          );

          const cases = [
            ('', 'Which planet is known as the Red Planet'),
            (
              'task: search result | query: ',
              'Which planet is known as the Red Planet',
            ),
            ('title: none | text: ', 'The cat sat on the mat'),
            ('', ''),
            ('prefix only, empty text: ', ''),
            ('', 'Unicode: café — naïve — 中文 — emoji 🎉'),
          ];

          for (final (prefix, text) in cases) {
            final legacyIds = encodeForEmbedding(legacyTokenizer, prefix, text);
            final adapterIds = adapter.encode(prefix, text).ids;
            expect(
              adapterIds,
              legacyIds,
              reason:
                  'prefix=$prefix text=$text: adapter ids diverged from '
                  'the legacy encodeForEmbedding call shape',
            );
          }
        },
      );

      test(
        'adapter reports null attentionMask/tokenTypeIds (Gemma SentencePiece '
        'has no notion of either — the forward pass pads/truncates internally)',
        () async {
          if (!tokenizerFile.existsSync()) {
            markTestSkipped('No local tokenizer asset at $_tokenizerPath.');
            return;
          }
          final adapter = await loadGemmaSentencePieceEmbeddingTokenizer(
            tokenizerFile.path,
          );
          final result = adapter.encode('', 'hello');
          expect(result.attentionMask, isNull);
          expect(result.tokenTypeIds, isNull);
        },
      );
    },
  );
}
