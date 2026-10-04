# flutter_edge_ai_embeddings

> **Renamed from [`flutter_gemma_embeddings`](https://pub.dev/packages/flutter_gemma_embeddings).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_embeddings/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

The **embedding tokenizers** for
[flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai): Gemma SentencePiece
and BERT-family WordPiece, plus the task-type prefixing and the routing that
picks between them. Android, iOS, macOS, Linux, Windows, Web.

Since 2.2.0 this is all it is. The seam an engine implements, the
background-isolate worker and the pooling moved into `flutter_edge_ai` itself, so
an engine package can implement embeddings without depending on this one — and
no engine does. What lives here is the part that cannot move: the tokenizer
implementations, which pull `dart_sentencepiece_tokenizer` and must stay out of
core's dart2wasm-clean graph.

Your app registers them, beside the backend that consumes them:

```dart
await FlutterEdgeAi.initialize(
  embeddingBackends: [LiteRtEmbeddingBackend()],   // from an engine package
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],
);
```

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-rag`, covers embedding models, the vector stores, and metadata filters.

## Usage

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  embeddingBackends: [LiteRtEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],
);
```

Two lists, because they answer different questions. The backend is the engine
that turns token ids into a vector; the tokenizer is what turns text into those
ids, and which one a model needs is a property of the MODEL — EmbeddingGemma is
SentencePiece whether LiteRT or ONNX Runtime runs it. Keeping them apart is why
neither engine package depends on this one, and why an app that never embeds
anything resolves neither.

Forget the second list and the first embedding throws a `StateError` naming the
package to add — it never silently falls back to a tokenizer with the wrong
convention.

`LiteRtEmbeddingBackend` provides the embedding model that
`FlutterEdgeAi.getActiveEmbedder()` returns, which text RAG
(`RagIndex.addText` / `searchText`) in
[`flutter_edge_ai_rag`](https://pub.dev/packages/flutter_edge_ai_rag) uses with
a storage provider from `flutter_edge_ai_sqlite` or `flutter_edge_ai_qdrant`.

## Web setup

The web embedding bundle moved to the LiteRT-LM package in `flutter_gemma_litertlm` 1.8.0 — it is
LiteRT.js, and it belongs with the package named after it. See
[flutter_edge_ai_litertlm's web setup](https://pub.dev/packages/flutter_edge_ai_litertlm#embeddings-on-web).

This package has no web assets of its own: on web its tokenizers run only for
backends that tokenize in Dart (WordPiece), while the LiteRT web arm tokenizes
inside `sentencepiece.js`.

## Platforms

| Platform | Support |
|----------|---------|
| Android / iOS | ✅ (via flutter_edge_ai_litertlm's FFI backend) |
| macOS / Linux / Windows | ✅ (via flutter_edge_ai_litertlm's FFI backend) |
| Web | ✅ (via flutter_edge_ai_litertlm's LiteRT.js backend, CDN) |

This package itself is pure Dart with no native/FFI code — the concrete
backend (and its native library) is owned by whichever engine package you add.

## Tokenizer profiles

Three adapters, picked by the model you load — a model's special-token
convention is not negotiable, and using the wrong one corrupts the vector
silently rather than failing:

| profile | convention | loader |
|---|---|---|
| Gemma (SentencePiece) | BOS 2, EOS 1, TaskType prefix | `loadGemmaSentencePieceEmbeddingTokenizer` |
| WordPiece (BERT / MiniLM) | `[CLS]` … `[SEP]` | `WordPieceEmbeddingTokenizer.fromJsonString` / `.fromPath` |
| SigLIP2 text tower | no BOS, one trailing EOS, lowercased, fixed 64-token width | `loadSiglipSentencePieceEmbeddingTokenizer` |

SigLIP2's ONNX export carries no `attention_mask`, and its head does not pool
over the sequence at all — `Siglip2TextModel` takes `last_hidden_state[:, -1, :]`,
the LAST position, which with right-padding is a pad token. So the 64-token width
has to live in the ids: the adapter pads (and truncates) to exactly 64 itself
rather than leaving it to the forward pass, and the pad id is first-order rather
than cosmetic.

`WordPieceEmbeddingTokenizer.fromPath` reads from disk and is **native only**;
on web it throws `UnsupportedError` — fetch the `tokenizer.json` yourself there
and use `fromJsonString`.

### Known limitation: the SigLIP2 profile is not selected automatically

The tokenizer router here has three outcomes — WordPiece, a SigLIP2 refusal, or Gemma.
A SigLIP2 `tokenizer.json` is BPE, so it would fall through to the **Gemma**
adapter, which injects BOS, skips the lowercasing and does not pad to 64: every
id in range, nothing thrown, and a vector that is quietly the wrong point in the
embedding space. The loader therefore **refuses** such a file rather than
embedding it wrongly.

Until a profile selector lands, reach the adapter by building the
`ForwardPassDescriptor` yourself, with
`loadSiglipSentencePieceEmbeddingTokenizer` as its tokenizer factory:

```dart
import 'package:flutter_edge_ai_embeddings/embedding_tokenizer.dart'
    show loadSiglipSentencePieceEmbeddingTokenizer;
```

That library is native-only, which is why it sits outside the package barrel.

**How the file is recognised.** SigLIP2 and Gemma share a vocabulary, but their
`tokenizer.json` files differ where it counts: SigLIP2 declares
`"padding": {"strategy": {"Fixed": 64}, "pad_id": 0}` and a `post_processor` of
`[Sequence A, <eos>]`, while a Gemma tokenizer has `"padding": null` and
`[<bos>, Sequence A]`. `isSiglip2TokenizerJson`
(`package:flutter_edge_ai_embeddings/tokenizer_convention.dart` — web-safe, so an
engine's web arm can apply the same rule) reads exactly those two blocks, and
requires both: plenty of models declare one alone.

### What the tokenizer loaders return

Both loaders return a tokenizer with any `padding` and `truncation` the file
declares switched OFF: `encode()` gives back bare content, never a fixed-width
row. Width and terminators belong to the profile — `encodeForSiglipEmbedding`
applies SigLIP2's 64-token rule itself — and to the forward pass, which owns the
engine's compiled `seqLen`.

This matters if you build a `ForwardPassDescriptor` by hand: do not expect the
file's `"padding": {"strategy": {"Fixed": 64}}` to have been applied for you.

The loaders throw `StateError` if the resolved `dart_sentencepiece_tokenizer`
accepts the calls that disable those settings and leaves them set anyway. That
is a check on the tokenizer's config, not a guarantee about `encode()`'s output.

### The task-type prefix

`TaskType` has two values and both prefixes are non-empty, and
`generateEmbedding` defaults to `TaskType.retrievalQuery` — so no caller can
embed without one. That is the intended contract for Gemma/Gecko.

It is not for a CLIP-family tower, whose vision side encodes an image with no
prefix at all, so **the SigLIP2 profile drops it**. Honoring one would put query
and document of the same string on two different points, both off the space the
two towers exist to share.

`WordPieceEmbeddingTokenizer` (MiniLM and other BERT-style models) still
concatenates the prefix. Those models are not trained with EmbeddingGemma's
prefixes either; making that configurable belongs with the profile selector.

## Building a new engine backend

Implement `EmbeddingForwardPass` (`load`/`run`/`close`/`outputDimension`/
`inputSequenceLength`) for your engine, expose a top-level factory tear-off
for it, and build an `EmbeddingBackendProvider` that calls
`CommonEmbeddingModel.create(descriptor: ForwardPassDescriptor(...), tokenizerPath: ...)`.
Declare `EmbeddingOutputContract.pooledFinal` if your engine's forward pass
already returns the final embedding, or `.tokenLevel` if it returns raw
per-token hidden states for core's `meanPoolAndNormalize` (exported by
`flutter_edge_ai`, re-exported here) to pool.
Pass `activeBackend:` too — the backend your forward pass really runs on. It is
optional, so nothing will make you, but it is what `EmbeddingModel.activeBackend`
reports to the app, and omitting it answers `null`. Never default it to CPU for
an engine that might use an accelerator: that reports a guess as a fact.
See `flutter_edge_ai_litertlm`'s `lib/src/embedding/` for a worked example.

## Troubleshooting

### `dlopen` / "library not found" (`libLiteRtLm`)

`flutter_edge_ai_litertlm` is the sole owner of the shared native library and
bundles it via its build hook. A stale Native-Assets cache after a native
version bump can leave the library unbundled, surfacing as an opaque `dlopen`
"no such file" on the first embedding call. Fix with a clean rebuild:

```bash
flutter clean
rm -rf ~/Library/Caches/flutter_gemma/native        # macOS
rm -rf ~/.cache/flutter_gemma/native                # Linux
# Windows: rmdir /s "%LOCALAPPDATA%\flutter_gemma\native"  (path may vary)
flutter pub get
```
