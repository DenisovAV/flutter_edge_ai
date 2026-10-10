---
name: flutter-edge-ai-onnx
description: Use when running ONNX models with flutter_edge_ai_onnx (ModelFileType.onnx) — ORT-GenAI text generation (e.g. Phi-3.5-mini) or ONNX embeddings — on macOS arm64, Linux x64, Windows x64, Android arm64, iOS arm64, or in the browser through Transformers.js. Also use when an ONNX install is routed to the wrong engine, genai_config.json is missing, or getActiveModel throws "No inference engine can handle this model" on another platform. For .litertlm models use flutter-edge-ai-inference; for .task, flutter-edge-ai-mediapipe.
---

# The ONNX engine

## Rules

1. Depend on `flutter_edge_ai` and `flutter_edge_ai_onnx`, and import both. The engine package does not re-export core.
2. Declare `fileType: ModelFileType.onnx`. Without it the install defaults to `task` and never reaches `OnnxEngine`.
3. An ORT-GenAI model is a directory — `genai_config.json`, the `.onnx` graph, its weights and a tokenizer. Install it with `fromHuggingFace(repo)`, which downloads the whole folder, or point `fromFile` at a local `genai_config.json`. A single-file download or a Flutter asset cannot produce it.
4. Native generation runs on macOS arm64, Linux x64, Windows x64, Android arm64 and iOS arm64. On any other native host no engine accepts the model and `getActiveModel` throws `No inference engine can handle this model`. Web is a separate arm with its own rules (below).
5. Android needs `minSdk 24` — the build hook fails the build below it. Phi-3.5-mini peaks near 3.7 GB of RAM, so target 8 GB devices.
6. Text only: no images, no audio, no LoRA.
7. Sampling follows the model's own config — `genai_config.json` natively, `generation_config.json` on web — which is greedy unless it sets `do_sample`. A `temperature`, `topK` or `topP` you pass overrides it and switches sampling on; `temperature: 0` or `topK: 1` keeps it greedy, natively, a `temperature` or `topP` without `topK` over a config with `top_k: 1` also gets a top-k (the family's, else 40); on web the seed is not applied yet and `topP` is ignored (Transformers.js samples with top-k only). On native `activeBackend` is `null` — ORT-GenAI picks the execution provider from `genai_config.json`, which the engine does not read; on web it reports the backend that loaded.

## Setup

```sh
flutter pub add flutter_edge_ai flutter_edge_ai_onnx flutter_edge_ai_embeddings
```

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_onnx/flutter_edge_ai_onnx.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: [OnnxEngine()],
  embeddingBackends: [OnnxEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],
);

await FlutterEdgeAi.installModel(
  modelType: ModelType.phi,
  fileType: ModelFileType.onnx,
).fromHuggingFace('microsoft/Phi-3.5-mini-instruct-onnx').install();

final InferenceModel model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
```

A repo with several execution-provider folders resolves to its CPU/mobile folder automatically — the bundled runtime is CPU-only.

A bundle shipped with the app:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.phi,
  fileType: ModelFileType.onnx,
).fromFile('$path/genai_config.json').install();
```

Sessions, chats and streaming work as in the flutter-edge-ai-inference skill, except `openSession` / `openChat`, which throw `UnsupportedError` here — one conversation at a time. Pass `modelType` to `createChat` for function calling; ONNX falls back to `ModelType.gemmaIt`.

## Web

On web `OnnxEngine` runs the model through Transformers.js. Install it by Hugging Face repo URL; the browser downloads and caches the files on first use:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.qwen,
  fileType: ModelFileType.onnx,
).fromNetwork('https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct').install();
```

The repo must be in Transformers.js layout, as the `onnx-community` ones are. ORT-GenAI repos such as `microsoft/Phi-3.5-mini-instruct-onnx` do not run in the browser. `fromFile` and `fromAsset` install on web without complaint and then throw `UnsupportedError` from the first `createSession` — on web the model identity has to be a repo, not a file. `fromBundled('<id>')` serves one from the app's own origin. `PreferredBackend.cpu` forces WASM; anything else tries WebGPU first.

Add to `web/index.html` `<head>`, before Flutter boots — the first script for generation, the second for embeddings:

```html
<script type="module">
window.transformersReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.0');
  window.transformers = m;
  return m;
})();
</script>
<script type="module">
window.ortReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/ort.bundle.min.mjs');
  m.env.wasm.wasmPaths = 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/';
  window.ort = m;
  return m;
})();
</script>
```

## Embeddings

`OnnxEmbeddingBackend` handles single-file `.onnx` or `.ort` embedding models, installed with `FlutterEdgeAi.installEmbedder()` like any other — see the flutter-edge-ai-rag skill for the indexing flow.

On native it takes WordPiece (BERT-style, e.g. all-MiniLM-L6-v2) and SentencePiece (e.g. EmbeddingGemma-300M-ONNX) models and runs on CPU: `activeBackend` is `PreferredBackend.cpu` and `preferredBackend` is not applied. On web it takes WordPiece models only — all-MiniLM-L6-v2 works there, EmbeddingGemma-300M-ONNX is native-only.
