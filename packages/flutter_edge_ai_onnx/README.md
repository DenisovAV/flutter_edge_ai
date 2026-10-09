# flutter_edge_ai_onnx

> **Renamed from [`flutter_gemma_onnx`](https://pub.dev/packages/flutter_gemma_onnx).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_onnx/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

ONNX Runtime engines for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai):
**text generation** via ORT-GenAI (`OnnxEngine`) and **embeddings** via plain
ONNX Runtime (`OnnxEmbeddingBackend`). On **native** platforms (macOS, Linux,
Windows, Android, iOS), both are pure `dart:ffi` — no JVM, no gRPC — and both
drive the native library from a long-lived worker isolate so no FFI pointer
ever has to cross an isolate boundary. On **Web** there is no FFI: generation
runs through Transformers.js and embeddings run through onnxruntime-web,
behind the same public API.

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-onnx`, covers ORT-GenAI generation and ONNX embeddings, native and through Transformers.js.

## Register

Embeddings also need `flutter_edge_ai_embeddings`, which supplies the tokenizers
this package asks core for:

```bash
flutter pub add flutter_edge_ai_embeddings
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
```

Either arm can be registered on its own — they don't depend on each other.

## Platform matrix

| Platform | Native archives | `OnnxEngine`/`OnnxEmbeddingBackend` enabled |
|---|---|---|
| macOS (Apple Silicon) | ✅ bundled | ✅ device-verified |
| macOS (Intel) | ❌ | ❌ |
| Linux x64 | ✅ bundled | ✅ device-verified |
| Windows x64 | ✅ bundled | ✅ device-verified |
| Android (arm64) | ✅ bundled (AAR-extracted) | ✅ device-verified |
| iOS (arm64) | ✅ bundled | ✅ device-verified |
| Web | N/A — Transformers.js + onnxruntime-web, no native archive | ✅ both arms |

`OnnxEngine.canHandle`/`OnnxEmbeddingBackend.createModel` are gated to
macOS arm64, Linux x64, Windows x64, Android arm64, and iOS arm64 —
device-verified end-to-end (generation +
embeddings) on macOS (~54 tok/s, M4 Pro), Linux (~5.3-5.8 tok/s), Windows
(~3.3 tok/s), and Android (FTL Pixel 8 Pro, ~10.4 tok/s, ~3.74 GB RSS for a
3.8B int4 model). On iOS the framework-embedding/dlopen path builds, signs,
installs and launches on a real iPhone, and generation runs (the
`@executable_path`-anchored dlopen resolves the single self-contained genai
xcframework — the same proven pattern as `flutter_edge_ai_litertlm`'s iOS
path). On an unsupported native host (macOS Intel, or any other native ABI)
`OnnxEngine` politely declines (logs why, lets another registered engine —
or core's own "no engine can handle this" error — take over) instead of
dlopen-ing a library the app may or may not have bundled. Web has no dlopen
step at all — `OnnxEngine`/`OnnxEmbeddingBackend` run there via the
Transformers.js/onnxruntime-web arms below instead.
`OnnxEmbeddingBackend.canHandle` stays extension-based on every platform for
a different reason (so a catch-all embedding backend like
`LiteRtEmbeddingBackend` never silently claims an `.onnx`/`.ort` file); its
platform gate lives in `createModel` instead, as a loud `StateError`.

Android needs **`minSdk 24`** — both the ORT and ORT-GenAI AARs declare
`minSdkVersion=24`; raise your app's `android/app/build.gradle(.kts)`
`minSdk` to 24 or higher if it's lower today. The device-verified Android
model (Phi-3.5-mini 3.8B int4) peaks at ~3.74 GB RSS — plan for 6 GB+ RAM
devices; smaller models scale down.

### Which output the embedding path reads

A session's outputs are preferred in the order `sentence_embedding` >
`pooler_output` > `last_hidden_state` > first declared. The first two are
already-pooled `[1, dim]` sentence embeddings and are copied verbatim; only
`last_hidden_state` is per-token and gets mean-pooled. A graph exposing both
`pooler_output` and `last_hidden_state` — SigLIP2's text tower does — would
otherwise fall through to the per-token output and be pooled a second time.

This is a heuristic on a name, and it is worth knowing where it stops being one.
Optimum `feature-extraction` exports (`sentence-transformers/`, `Xenova/` MiniLM
and friends) declare no `pooler_output` at all, so they are unaffected. A graph
produced by exporting `BertModel` directly does declare one — BERT's tanh NSP
pooler — and this preference will now read that instead of mean-pooling the
hidden states. That head is not a sentence embedding and is not L2-normalized;
if you export a BERT encoder yourself, export it for feature extraction, or
strip the pooler. Which output to read is really a property of the model
profile, not of the output's name, and should move there.

## Inference — `OnnxEngine`

Text-only, greedy decoding, one session at a time (v1). No vision, no audio,
no LoRA. Models install as `ModelFileType.onnx` and use ORT-GenAI's own chat
template (`OgaTokenizerApplyChatTemplate`) — the engine never builds turn
markers itself.

`activeBackend` is `null`: ORT-GenAI picks the execution provider from the
model's `genai_config.json`, which the plugin never reads, so there is no honest
answer to report.

### Model layout: a directory, not a file

An ORT-GenAI model is a **directory**, not a single file:

```
my-model/
├── genai_config.json
├── model.onnx (+ model.onnx_data for the external-weights case)
└── tokenizer files (tokenizer.json, tokenizer_config.json, …)
```

`OnnxEngine.createModel` takes that directory's `genai_config.json` and loads
the **parent directory** as the model. There are two ways to get the directory
onto the device.

**From a Hugging Face repo (one call).** `OnnxHuggingFaceResolver` lists the
repo's file tree, picks an execution-provider folder, and installs every file
in it into a per-model subdirectory — so `fromHuggingFace(repo)` downloads the
whole ORT-GenAI bundle. The resolver rides on `OnnxEngine` via
`HuggingFaceResolverSource`, so registering the engine is enough:

```dart
await FlutterEdgeAi.initialize(inferenceEngines: [OnnxEngine()]);

final install = await FlutterEdgeAi.installModel(
  // ONNX repos declare no model family — the caller's modelType is used as-is.
  modelType: ModelType.general,
  fileType: ModelFileType.onnx, // selects the ONNX resolver
).fromHuggingFace('microsoft/Phi-3.5-mini-instruct-onnx').install();
```

A repo that ships several EP variants (`cpu_and_mobile/…`, `cuda/…`) resolves
to a **CPU/mobile** folder automatically — the bundled ORT-GenAI runtime is
CPU-only, so a CPU/mobile folder is preferred over any GPU export. (A repo that
ships *only* GPU variants still falls back to its GPU folder — flagged in
`install.notes`, which records the chosen folder either way.) Pin a specific folder with
`OnnxHuggingFaceResolver(variant: 'cpu_and_mobile/cpu-int4-…')` passed to
`initialize(huggingFaceResolvers: [...])`; a pinned GPU variant is installed but
flagged in `notes` as one the CPU-only runtime may fail to load.

**From a local directory.** If you ship the bundle yourself (an asset, or a
directory you pre-populate), point `fromFile` at its `genai_config.json`:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.general,
  fileType: ModelFileType.onnx,
).fromFile('/path/to/my-model/genai_config.json').install();
```

Either way, pointing `modelPath` at a directory missing `genai_config.json`
fails loudly with a `StateError` naming the gap, rather than a confusing native
error.

### `ORT_LIB_PATH` — you don't need to configure anything

ORT-GenAI resolves the plain ONNX Runtime library at its own native
`InitApi()` time via a **bare-name `dlopen("libonnxruntime.dylib")`**, with a
`dladdr`-based "look next to my own binary" fallback. Under Flutter's Native
Assets `.framework` wrapping, `onnxruntime` and `onnxruntime-genai` land in
two *separate* `.framework` bundles, so that fallback can't find it. Before
opening the GenAI library, `GenAiFfiClient` `dladdr`-resolves the already-open
ORT library's real on-disk path and exports it as the `ORT_LIB_PATH`
environment variable — GenAI's own sanctioned override, checked first inside
`InitApi()`. This needs no Podfile step, no packaging change, no app-level
configuration; it just works.

For host tests / local dev, `FLUTTER_GEMMA_ORT_GENAI_LIBS` (a directory
containing both platform-default-named dylibs) bypasses the CodeAsset bundle
entirely — see `test/onnx_generation_host_smoke_test.dart`.

### On web (Transformers.js)

On Web, `OnnxEngine` doesn't drive native ORT-GenAI at all — it runs the model
through [Transformers.js](https://huggingface.co/docs/transformers.js) v4 in
the browser. The model identity is a **Hugging Face repo id**
(e.g. `onnx-community/Qwen2.5-0.5B-Instruct`), not a directory, and install is
**fileless**: `ModelFileType.onnx` just marks the repo id active — core never
downloads model bytes — and Transformers.js fetches and caches the repo
itself the first time you run inference. Each call runs a stateless
`pipeline()` and resends the full chat history (Transformers.js has no
persistent session), formatted with the model's own `chat_template`.
`PreferredBackend.cpu` pins WASM; anything else tries WebGPU first and falls
back to WASM. Same constraints as native — text-only, no vision, no audio, no
LoRA. See [Web setup](#web-setup) for the required `web/index.html` shim.

## Embeddings — `OnnxEmbeddingBackend`

A plain ONNX Runtime forward pass (no ORT-GenAI, no text generation) over an
`.onnx`/`.ort` embedding model directory. One factory handles both:

- **WordPiece / BERT-style** models (e.g. all-MiniLM-L6-v2) — `tokenLevel`
  output contract, mean-pooled + normalized client-side.
- **SentencePiece** models (e.g. EmbeddingGemma-300M-ONNX) — `pooledFinal`
  output contract (the model's own `sentence_embedding` output).

The output contract and mask/`token_type_ids` requirements are discovered
from the session's actual graph once it opens — no per-model configuration
needed. Priority 10 (above `LiteRtEmbeddingBackend`'s catch-all priority 0),
so registering both and installing an `.onnx`/`.ort` model routes here.

On native the embedder reports `activeBackend == cpu`: no execution provider is
appended, so plain ORT runs on CPU and `preferredBackend` is not applied. On web
it is `null`.

For host tests / local dev, `FLUTTER_GEMMA_ORT_LIBRARY` overrides the
resolved ORT library path directly (mirrors the inference arm's
`FLUTTER_GEMMA_ORT_GENAI_LIBS`).

`OnnxEmbeddingBackend` also runs on **Web**, via
[onnxruntime-web](https://github.com/microsoft/onnxruntime) (WebGPU/WASM)
instead of the native FFI client. This release supports WordPiece/BERT-style
embedding models such as
[all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
on Web; SentencePiece models such as
[EmbeddingGemma-300M-ONNX](https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX)
are native-only. See [Web setup](#web-setup).

## What v1 does not do

- No vision, no audio, no multimodal input on the inference arm — text only.
- No LoRA.
- Greedy decoding only (no sampling parameters exposed yet).
- One inference session at a time (`createSession` closes any live session
  before opening a new one, same as every other engine in this monorepo).

## Web setup

Web needs a small `web/index.html` shim before `FlutterEdgeAi.initialize()`
runs — the same readiness-handshake pattern `flutter_edge_ai_litertlm` uses for
`@litert-lm/core`. Add the shim for whichever arm(s) you register:

```
<!-- Transformers.js v4 (OnnxEngine web generation). -->
<script type="module">
window.transformersReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.0');
  window.transformers = m;
  return m;
})();
</script>

<!-- onnxruntime-web (OnnxEmbeddingBackend web embeddings). -->
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
either module's `dart:js_interop` bindings, so the shim must run before the
Flutter app boots (i.e. in `<head>`, ahead of `flutter_bootstrap.js`).

## See also

- [`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai) — the core
  package this engine plugs into.
- [`flutter_edge_ai_litertlm`](https://pub.dev/packages/flutter_edge_ai_litertlm) —
  the LiteRT-LM equivalent, with broader platform support today; its
  `LiteRtEmbeddingBackend` is the LiteRT counterpart of `OnnxEmbeddingBackend`.
- [`flutter_edge_ai_embeddings`](https://pub.dev/packages/flutter_edge_ai_embeddings) —
  the tokenizers this package's embedding arm also needs (see [Register](#register)).
