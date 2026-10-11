---
title: ONNX Runtime
description: Run ONNX models on-device — text generation via ORT-GenAI and embeddings via plain ONNX Runtime — across five native platforms (dart:ffi) and the web (Transformers.js / onnxruntime-web).
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

flutter_edge_ai's engines are **pluggable**: you register them in
`FlutterEdgeAi.initialize(...)`, and the registry picks one per model by its
declared `ModelFileType`. `flutter_edge_ai_onnx` adds two of them from the
[ONNX Runtime](https://onnxruntime.ai) family:

- **`OnnxEngine`** — text generation via **ORT-GenAI**.
- **`OnnxEmbeddingBackend`** — embeddings via **plain ONNX Runtime** (no
  generation).

On **native** platforms both are pure `dart:ffi` — no JVM, no gRPC — and each
drives the native library from a long-lived worker isolate, so no FFI pointer
crosses an isolate boundary. On **Web** there is no FFI: generation runs through
Transformers.js and embeddings through onnxruntime-web, behind the same public
API. Either arm can be registered on its own — they don't depend on each other.

## Platforms

Native support is **arm64/x64-gated** — each host is device-verified end-to-end
(generation + embeddings):

| Platform | Runtime | `OnnxEngine` / `OnnxEmbeddingBackend` |
|----------|---------|----------------------------------------|
| macOS (Apple Silicon) | ORT-GenAI + ORT via `dart:ffi` | ✅ ~54 tok/s (M4 Pro) |
| Linux x64 | ORT-GenAI + ORT via `dart:ffi` | ✅ ~5.3–5.8 tok/s |
| Windows x64 | ORT-GenAI + ORT via `dart:ffi` | ✅ ~3.3 tok/s |
| Android (arm64) | ORT-GenAI + ORT via `dart:ffi` | ✅ ~10.4 tok/s (Pixel 8 Pro) |
| iOS (arm64) | ORT-GenAI + ORT via `dart:ffi` | ✅ device-verified |
| Web | Transformers.js + onnxruntime-web (WebGPU/WASM) | ✅ both arms |

> On an unsupported native host (macOS Intel, or any other native ABI)
> `OnnxEngine` politely declines and logs why, letting another registered engine
> take over. Android needs **`minSdk 24`** (both ORT and ORT-GenAI AARs declare
> `minSdkVersion=24`). The native library co-location — ORT loaded next to
> ORT-GenAI — is handled for you: the build hook bundles the two libraries side
> by side, and on macOS and Linux the package points ORT-GenAI at the bundled
> ORT at run time. You don't configure anything.

## Setup

Add the package and register whichever arm(s) you use at startup:

```
dependencies:
  flutter_edge_ai: latest_version
  flutter_edge_ai_onnx: latest_version         # ONNX Runtime engines
  flutter_edge_ai_embeddings: latest_version   # tokenizers, for embeddings
```

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_onnx/flutter_edge_ai_onnx.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: [OnnxEngine()],            // text generation
  embeddingBackends: [OnnxEmbeddingBackend()], // embeddings
  embeddingTokenizers: [GemmaEmbeddingTokenizers()], // flutter_edge_ai_embeddings
);
```

## Install a model

ONNX models install with `fileType: ModelFileType.onnx`. What that means differs
by platform.

**Native — a directory, not a file.** An ORT-GenAI model is a **directory**:
`genai_config.json`, `model.onnx` (plus `model.onnx_data` for external weights),
and tokenizer files. `OnnxEngine` takes the tracked `genai_config.json`'s
**parent directory** as the model directory.

`fromHuggingFace(repo)` installs that whole directory for you: the ONNX resolver
(carried by `OnnxEngine`, so registering the engine is enough) lists the repo,
picks an execution-provider folder, and downloads every file in it. A repo with
several EP variants resolves to a **CPU/mobile** folder — the bundled runtime is
CPU-only — unless you pin one with `OnnxHuggingFaceResolver(variant: …)`:

```dart
await FlutterEdgeAi.installModel(
  // ONNX repos declare no family — the caller's modelType is used as-is.
  modelType: ModelType.general,
  fileType: ModelFileType.onnx,
).fromHuggingFace('microsoft/Phi-3.5-mini-instruct-onnx').install();
```

Or ship the bundle yourself and point `fromFile` at its `genai_config.json`:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.general,
  fileType: ModelFileType.onnx,
).fromFile('/path/to/my-model/genai_config.json').install();
```

**Web — fileless.** The model identity is a **Hugging Face repo id**;
Transformers.js resolves, fetches, and caches it the first time you run
inference. Install just marks the repo id active — core never downloads model
bytes:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.general,
  fileType: ModelFileType.onnx,
).fromNetwork('https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct').install();
```

From here the code is identical to any other engine:

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final session = await model.createSession();
await session.addQueryChunk(const Message(text: 'Hello!', isUser: true));
final response = await session.getResponse();
```

## Generation — `OnnxEngine`

Text-only, one session at a time (v1): no vision, no audio, no LoRA. Sampling
follows the model's own config (`genai_config.json` natively,
`generation_config.json` on Web), which is greedy unless it sets `do_sample`;
the `temperature`, `topK` and `topP` you pass override it, and `temperature: 0`
or `topK: 1` keeps decoding greedy. Natively, a temperature or `topP` without
`topK` over a config with `top_k: 1` also gets a top-k (the family's, else 40),
so it samples. On Web the seed is not applied yet and `topP` is ignored
(Transformers.js samples with top-k only); each is said once when set. Prompts use the model's own chat template
(ORT-GenAI's `OgaTokenizerApplyChatTemplate` natively; the model's
`chat_template` on Web) — the engine never builds turn markers itself.
On native, `preferredBackend` is not applied at all: neither ORT client appends an
execution provider. For inference, ORT-GenAI picks the provider from the model
directory's `genai_config.json`, which `flutter_edge_ai_onnx` never reads, so the inference
model's `activeBackend` is `null` rather than a guess. Embeddings run on plain
ORT with no provider appended, which is CPU, and the embedder reports `cpu`.

`PreferredBackend.cpu` pins WASM on Web; anything else tries WebGPU first and
falls back to WASM.

## Embeddings — `OnnxEmbeddingBackend`

A plain ONNX Runtime forward pass over an `.onnx`/`.ort` embedding model. The
tokenizer provider you register (`GemmaEmbeddingTokenizers` from
`flutter_edge_ai_embeddings`) handles both tokenizer families, and the **output
dimension is model-dependent** (not a fixed 768):

- **WordPiece / BERT-style** models (e.g. all-MiniLM-L6-v2, 384-dim) —
  mean-pooled + normalized client-side.
- **SentencePiece** models (e.g. EmbeddingGemma-300M-ONNX) — the model's own
  pooled `sentence_embedding` output. **Native only** — on Web, embeddings are
  WordPiece/BERT-style only in this release (a pure-Dart SentencePiece parser is
  pending).

A SigLIP 2 `tokenizer.json` is a third convention the provider does **not**
select yet, and it is BPE — so it would otherwise be read as Gemma and return a
plausible but wrong vector. The provider refuses it instead, with a message
pointing at `loadSiglipSentencePieceEmbeddingTokenizer`, which you can wire into
a `ForwardPassDescriptor` yourself — see
[SigLIP 2 text tower](/docs/models#siglip-2-text-tower-onnx-manual-wiring) for
the profile and how to recognise a matching export.

The output contract and mask requirements are discovered from the session's
actual graph once it opens — no per-model configuration. It registers at
priority 10 (above `LiteRtEmbeddingBackend`'s catch-all priority 0), so with
both registered an `.onnx`/`.ort` model routes here. See
[Embeddings & RAG](/docs/embeddings-and-rag) for the shared embedding API.

## Web setup

Web needs a small `web/index.html` shim before `FlutterEdgeAi.initialize()` runs
(the same readiness-handshake pattern the other web arms use). Add the shim for
whichever arm(s) you register, in `<head>`, ahead of `flutter_bootstrap.js`:

```
<!-- Transformers.js v4 — OnnxEngine web generation. -->
<script type="module">
window.transformersReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.0');
  window.transformers = m;
  return m;
})();
</script>

<!-- onnxruntime-web — OnnxEmbeddingBackend web embeddings. -->
<script type="module">
window.ortReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/ort.bundle.min.mjs');
  m.env.wasm.wasmPaths = 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/';
  window.ort = m;
  return m;
})();
</script>
```

Dart awaits `window.transformersReady` / `window.ortReady` before touching
either module, so the shim must run before the Flutter app boots.

## See also

- [Embeddings & RAG](/docs/embeddings-and-rag) — the shared embedding API this
  backend plugs into.
- [Models](/docs/models) — the full supported-model matrix.
- [Packages](/docs/packages) — every opt-in engine and backend, including
  `flutter_edge_ai_onnx`.

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-onnx`](/docs/package-skills), the skill that teaches it ORT-GenAI generation and ONNX embeddings, native and through Transformers.js.
