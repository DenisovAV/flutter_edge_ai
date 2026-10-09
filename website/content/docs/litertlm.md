---
title: LiteRT-LM
description: The primary .litertlm engine — on-device inference over dart:ffi (LiteRT-LM C API) on all five native platforms plus a text-only web preview, with CPU / GPU / NPU acceleration and a LiteRT embedding backend.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_litertlm` is the **primary `.litertlm` engine**. (Core registers
no engine by default — you opt in by registering `LiteRtLmEngine()`.) It runs
`.litertlm` models through `dart:ffi` straight onto the **LiteRT-LM C API** — no
JVM, no gRPC — and it is the **primary desktop engine** (macOS, Windows, Linux);
[ONNX Runtime](/docs/onnx) also runs on desktop, and macOS and Windows can additionally
use [Built-in AI](/docs/builtin-ai). The native library is fetched at build time via
**Native Assets** (SHA256-verified, from the `native-v0.18.0-d` GitHub release), so
there's no manual native setup.

The same package also ships **`LiteRtEmbeddingBackend`**, the LiteRT C API
embedding backend — see [Embeddings & RAG](/docs/embeddings-and-rag).

## Platforms

| Platform | Support |
|----------|---------|
| Android | ✅ FFI (GPU via OpenCL, NPU on Qualcomm — opt-in via `qualcomm_npu`) |
| iOS | ✅ FFI (GPU via Metal on device; CPU on simulator) |
| macOS / Linux | ✅ FFI (GPU via Metal / Vulkan; NPU on Qualcomm Linux arm64 — opt-in via `qualcomm_npu`) |
| Windows | ✅ FFI (CPU + GPU via DirectX 12 + Intel NPU) |
| Web | ⚠️ early preview via `@litert-lm/core` (text-only) |

> **Web is a text-only preview.** It runs through `@litert-lm/core` (WebGPU/WASM)
> and supports function calling and thinking, but **not** vision, audio or LoRA. Qwen3's emitted `<think>` tags are parsed by core on Web. Native platforms have the full feature set. On web you also need the JS
> handshake in `web/index.html` (see [Web setup](#web-setup)).

## Setup

Add the package and register `LiteRtLmEngine()` at startup, alongside any other
engines your app uses:

```
dependencies:
  flutter_edge_ai: latest_version
  flutter_edge_ai_litertlm: latest_version   # .litertlm inference engine
```

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine()],
);
```

`LiteRtLmEngine` claims models whose declared `ModelFileType` is `litertlm`; pass
it alongside `MediaPipeEngine` (from `flutter_edge_ai_mediapipe`) if your app also
uses `.task` models.

## Install a `.litertlm` model

> **Declare the file type.** `installModel` defaults `fileType` to
> `ModelFileType.task`, so a `.litertlm` model **must** set
> `fileType: ModelFileType.litertlm` explicitly — otherwise it is routed to
> MediaPipe instead of this engine.

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm,
).fromNetwork(
  'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
  token: 'hf_...',
).install();

// Create the model once and keep it for the app's lifetime.
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  preferredBackend: PreferredBackend.gpu,
);

final session = await model.createSession();
await session.addQueryChunk(const Message(text: 'Hello!', isUser: true));
await for (final chunk in session.getResponseAsync()) {
  print(chunk);
}
await session.close();
```

## Backends & acceleration

Pick the accelerator with `preferredBackend:` on `getActiveModel`:

| Backend | Where |
|---------|-------|
| `cpu` | All native platforms |
| `gpu` | OpenCL (Android), Metal (Apple), DirectX 12 / WebGPU (Windows), Vulkan / WebGPU (Linux); on web the runtime picks WebGPU or WASM itself and `preferredBackend` is not applied |
| `npu` | Qualcomm on Android and on Linux arm64 (opt-in, `.litertlm`), and Windows (Intel LunarLake / PantherLake) |

GPU is the right default, but it is not uniformly faster: on Android the win is
in **prefill**, and decode can be slower than CPU. One measured pair — Galaxy S26,
the official int8 Qwen2.5-1.5B bundle — has GPU prefill at 2.8× CPU while GPU
decode runs *below* it, 21.8 against 27.8 tok/s
([LiteRT-LM#1748](https://github.com/google-ai-edge/LiteRT-LM/issues/1748#issuecomment-5549035313)).
That is one device and one bundle, not a rule — but if your app is dominated by
long replies rather than long prompts, measure both before assuming.

The GPU runs the model at half precision unless you ask otherwise, and the
published Gemma 4 files ask for it. From about 2,000 prompt tokens, Gemma 4 then
copies digits wrongly on some GPUs (seen on Adreno and Metal). `activationDataType: ActivationDataType.float32` on
`getActiveModel` fixes it at the cost of a slower prefill; left unset, the model
file decides. It applies to the text decoder of `.litertlm` models on Android,
iOS and desktop — not on web, and not to the vision or audio encoders, which
keep what the model file asks for. `float32` also needs more GPU memory, and a
GPU engine that cannot be created falls back to CPU silently, so read
`model.activeBackend` afterwards. Every `flutter_edge_ai_litertlm` release
applies it (it arrived in `flutter_gemma_litertlm` 1.8.3; older versions ignore it). See [Troubleshooting → Wrong numbers on
GPU](/docs/troubleshooting#wrong-numbers-on-gpu).

Windows NPU ships the Intel dispatch stack — `LiteRtDispatch.dll` + the OpenVino
runtime + TBB — inside the Windows native archive.

**Android NPU is opt-in.** Qualcomm licenses its QNN runtime for redistribution
inside an application only, so the package carries just LiteRT's dispatch
library and your app asks for the rest in its `pubspec.yaml` (the workspace
root's, if the app is a pub workspace member):

```
hooks:
  user_defines:
    flutter_edge_ai_litertlm:
      qualcomm_npu: true
```

The build hook then fetches `com.qualcomm.qti:qnn-runtime:2.50.0` from Maven
Central once, verifies its SHA-256, raises the Hexagon libraries to the 16 KB
page alignment Google Play requires, and bundles them: about 22 MB more to
download and 83 MB more installed, plus a copy of the same size made on the
first NPU run, because the DSP loads them from files. Setting the flag accepts Qualcomm's AI
Stack License; the hook prints where its `LICENSE.pdf` is. Offline or behind a
mirror, add `qualcomm_npu_maven_url: <maven base URL>` or
`qualcomm_npu_aar: <path to the same AAR>`. Without the flag, `npu` on Android
falls back to GPU, then CPU, and the log says how to enable it.

**Linux arm64 NPU takes the same flag.** On a Qualcomm Linux board with a
Hexagon V68–V81 compute DSP (Dragonwing QCS6490, QCS8275 — the Arduino
VENTUNO Q — QCS9075, …), `qualcomm_npu: true` bundles the stack into the
Linux arm64 build. Qualcomm publishes no Maven artifact for Linux, so the hook
reads the 14 libraries it needs out of Qualcomm's public QAIRT 2.50 SDK zip with
HTTP range requests — about 32 MB of the 2.6 GB archive — checks each one
against a pinned SHA-256, and caches them; about 90 MB more installed. Offline,
download the zip yourself and add `qualcomm_npu_qairt_zip: <path>`. On the
board, Qualcomm's FastRPC library has to be present (`qcom-fastrpc1` on Ubuntu;
Qualcomm's images ship it) and the user has to be in group `fastrpc`
(`sudo usermod -aG fastrpc $USER`, then log in again). Without either, `npu`
falls back to GPU, then CPU, and the log names what is missing. Use the bundle
compiled for your SoC, e.g. `gemma-4-E2B-it_qualcomm_qcs8275.litertlm`. A Linux
x64 build ignores the flag.

<Warning>

**NPU is a Gemma 4 story today.** Our NPU verification runs Gemma 4 bundles, and
those work on both vendors. The **Gemma 3** family does not, and it fails
silently — the model answers from the first prefill chunk alone, fluently,
with no error and nothing in the log:

- **Qualcomm.** A compiled bundle carries a prefill mask of
  `2 B × num_attention_heads × prefill × (cache_length + prefill)`. Above ~1 MiB
  every chunk after the first is dropped. For the 4-head Gemma 3 bundles that
  makes **896** the largest working `cache_length` at prefill 128 — and *every*
  published `qualcomm.*` Gemma 3 bundle is built above the line (270M at cache
  4096 is 4.125 MiB, 1B ekv1280 is 1.375 MiB). A 16-head model such as Qwen3-0.6B
  has no working value at prefill 128 at all.
- **Intel.** The second chunk is lost regardless of mask size — a different
  defect on the OpenVINO path, which Gemma 4 bundles do not hit.

Both are tracked upstream in
[LiteRT-LM#3508](https://github.com/google-ai-edge/LiteRT-LM/issues/3508).
Because the safe context is a property of the compiled bundle, `maxTokens` is
**not** clamped up to 1024 on the NPU attempt (it is on CPU and GPU — see below),
so pass the `cache_length` the bundle was compiled for. Note that requesting
`PreferredBackend.npu` does not guarantee the NPU runs: if it fails to
initialize, the engine falls back to GPU and then CPU, and the floor applies
again to those attempts — so a value chosen for an NPU bundle is raised to 1024
on the fallback rather than crashing it. The NPU candidate is attempted only on
Windows and on Android phones with Qualcomm FastRPC; on other Android phones,
macOS, Linux and iOS it is skipped, because nothing there can run it — and on
macOS the native runtime was measured accepting `npu` anyway, which made
`activeBackend` report an NPU that does not exist on the machine. On Windows
the check is per OS, so a PC without an Intel NPU still attempts it, and
`activeBackend` can then report `npu` while the model runs elsewhere.

</Warning>

## `maxTokens` is the CONTEXT window, not the reply length

`maxTokens` (on `getActiveModel` / `createModel`) sizes the whole **context
window** — system prompt + history + message **plus** the generated output (the
KV-cache budget), not the response length. CPU/GPU `.litertlm` bundles bake a
minimum `kv_cache_max_len` (1024 for the supported bundles), so this engine
**clamps `maxTokens` up to 1024** (with
a log warning) to avoid a native KV-cache crash — on every backend attempt except
the NPU one, where the bundle's own compiled `cache_length` governs instead (see
the NPU warning above).

To cap **generation length**, use `maxOutputTokens` on the session:

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096); // context
final session = await model.createSession(maxOutputTokens: 100);  // reply cap
```

## Web setup

`.litertlm` web inference runs via `@litert-lm/core`. The ESM doesn't assign
window globals, so add this handshake to your `web/index.html` `<head>` — Dart
awaits `window.litertLmReady` (which resolves to the `Engine` constructor):

```
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.17.1/+esm');
  window.Engine = m.Engine;
  return m.Engine;
})();
</script>
```

Native platforms need no web setup.

## See also

- [Desktop Support](/docs/desktop) — the FFI path on macOS / Windows / Linux.
- [Embeddings & RAG](/docs/embeddings-and-rag) — the `LiteRtEmbeddingBackend` this package ships.
- [Packages](/docs/packages) — the full opt-in package matrix and APIs.
