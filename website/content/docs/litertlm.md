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
**Native Assets** (SHA256-verified, from the `native-v0.18.0-f` GitHub release), so
there's no manual native setup.

The same package also ships **`LiteRtEmbeddingBackend`**: EmbeddingGemma 2 from
one `.litertlm` bundle (native: text since 1.13.0, images from the 440m and
740m bundles since 1.13.1, audio and combined inputs from the 740m bundle;
Web, on WebGPU: text and images since 1.13.1, audio and combined inputs since 1.13.2) and
EmbeddingGemma 1 / Gecko
`.tflite` models through the LiteRT C API (and LiteRT.js on web) — see
[Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2).

## Platforms

| Platform | Support |
|----------|---------|
| Android | ✅ FFI (GPU via OpenCL; NPU on Qualcomm or Google Tensor (G6 run, G5 not run) — opt-in via `qualcomm_npu` / `google_tensor_npu`) |
| iOS | ✅ FFI (GPU via Metal on device; CPU on simulator) |
| macOS / Linux | ✅ FFI (GPU via Metal / Vulkan; NPU on Qualcomm Linux arm64 — opt-in via `qualcomm_npu`) |
| Windows | ✅ FFI (CPU + GPU via DirectX 12 + Intel NPU) |
| Web | ⚠️ early preview via `@litert-lm/core` (text-only) |

> **Web is a text-only preview.** It runs through `@litert-lm/core` (WebGPU/WASM)
> and supports function calling and thinking, but **not** vision or audio; core
> parses `<think>` tags from any model that emits them. Only the dedicated
> `-web.litertlm` exports load (Gemma 4 and Gemma 3n today): a native `.litertlm`
> installs on web and then fails at the first generation. Native platforms add
> vision and audio. LoRA is not supported on any `.litertlm` path: a session
> `loraPath` throws `UnsupportedError`, and an adapter installed with
> `withLora…` is not applied. Use a MediaPipe `.task` model, or natively a
> `.gguf` through [llama.cpp](/docs/llama). On web you
> also need the JS handshake in `web/index.html` (see [Web setup](#web-setup)).

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
  'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm',
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
| `npu` | Qualcomm on Android and on Linux arm64, Google Tensor on Android (G6 run, G5 not run; both opt-in, `.litertlm`), and Windows (Intel Lunar Lake; Panther Lake builds not run) |

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
file decides, except that a FunctionGemma bundle declaring no
`prefer_activation_type` gets `float32` on its GPU attempt (litertlm 1.14.0),
because at half precision it answers with nothing. It applies to the text decoder of `.litertlm` models on Android,
iOS and desktop — not on web, and not to the vision or audio encoders, which
keep what the model file asks for. `float32` also needs more GPU memory, and a
GPU engine that cannot be created falls back to CPU with only a WARNING line in
the log, so read `model.activeBackend` afterwards, or turn the fallback off with
`LiteRtLmEngine(backendFallback: false)`. Every `flutter_edge_ai_litertlm` release
applies it (it arrived in `flutter_gemma_litertlm` 1.8.3; older versions ignore it). See [Troubleshooting → Wrong numbers on
GPU](/docs/troubleshooting#wrong-numbers-on-gpu).

Windows NPU ships the Intel dispatch stack — `LiteRtDispatch.dll` + the OpenVino
runtime + TBB — inside the Windows native archive. LLMs load on it from
`flutter_edge_ai_litertlm` 1.15.0; 1.7.0 through 1.14.0 failed the load or ended
the process (`0xC0000409`, LiteRT-LM#4023).

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
`qualcomm_npu_aar: <path to the same AAR>`. Without the flag, a bundle
compiled for an NPU is refused with a `BackendInitException` that says how to
enable it; a generic bundle never runs on the NPU, flag or not.

**Google Tensor has its own flag.** A bundle compiled for a Tensor NPU
(`…_Google_Tensor_G5.litertlm`, `…_Google_Tensor_G6.litertlm`) runs on a Pixel
with that Tensor generation and Android 16 or later (not a `BP2A` build,
which LiteRT does not run the NPU on) when the app sets
`google_tensor_npu: true` in the same `user_defines` block. The build then
bundles `libLiteRtDispatch_GoogleTensor.so`, which we build from the pinned
LiteRT source; Google's Tensor SDK terms cover that directory too. The runtime
it drives, `libedgetpu_litert.so`, is part of the Pixel system image. Run so
far on Tensor G6 Pixels with debug builds (Gemma 4 E2B text, images and audio;
EmbeddingGemma 2 270m and 440m); a Tensor G5 and a release-signed build are not
run yet.

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
(`sudo usermod -aG fastrpc $USER`, then log in again). Without either, a bundle
compiled for an NPU is refused with a `BackendInitException` that names what is
missing. Use the bundle compiled for your SoC. Google publishes Linux-board bundles for the QCS8275 only (Gemma 4 E2B, EmbeddingGemma 2; see the [Model Registry](/docs/registry)): install `LiteRtLmModels.gemma4E2bIt.npuQcs8275` from the catalog, since the file is no longer on the repository's `main`. The QCS6490 and QCS9075 have the stack but no bundle to run. A Linux
x64 build ignores the flag.

<Warning>

**EmbeddingGemma 2 on the NPU** uses the same flag on Qualcomm Android and
Linux arm64, with the per-SoC bundles, and never falls back: see
[Embeddings & RAG](/docs/embeddings-and-rag#embeddinggemma-2-on-a-qualcomm-npu).
Google Tensor G5/G6 bundles (270m, 440m, 740m) take `google_tensor_npu: true` instead
(from 1.15.0): see
[EmbeddingGemma 2 on a Google Tensor NPU](/docs/embeddings-and-rag#embeddinggemma-2-on-a-google-tensor-npu).
On Windows x64 the Intel Panther Lake bundles need no flag (from 1.13.2; not yet run on an Intel NPU): see
[EmbeddingGemma 2 on an Intel NPU](/docs/embeddings-and-rag#embeddinggemma-2-on-an-intel-npu).

**For LLMs, NPU is a Gemma 4 story today.** Our NPU runs use Gemma 4 E2B bundles, and
those work on Qualcomm (SM8750, QCS8275), the Intel Lunar Lake NPU and Google Tensor G6.
The Panther Lake and Tensor G5 builds are not run (see the [Model Registry](/docs/registry#gemma-4-e2b-it)). The **Gemma 3** family
does not on Qualcomm or Intel (Tensor not measured), and it fails
silently — the model answers from the first prefill chunk alone, fluently,
with no error and nothing in the log:

- **Qualcomm.** A compiled bundle carries a prefill mask of
  `2 B × (attention heads ÷ KV heads) × prefill × (cache_length + prefill)`. Above
  ~1 MiB every chunk after the first is dropped. For Gemma 3 (4 attention heads
  per KV head) that makes **896** the largest working `cache_length` at prefill
  128 — and *every* published Gemma 3 bundle for a Qualcomm NPU
  (`gemma3-270m-it-q8.qualcomm.<soc>`, `Gemma3-1B-IT_q4_ekv1280_<soc>`) is built above the line
  (270M at cache 4096 is 4.125 MiB, 1B ekv1280 is 1.375 MiB). Garbled Qwen3
  output on the NPU is a different bug
  ([LiteRT-LM#3846](https://github.com/google-ai-edge/LiteRT-LM/issues/3846)).
- **Intel.** The second chunk is lost regardless of mask size — a different
  defect on the OpenVINO path, which Gemma 4 bundles do not hit.

Both are tracked upstream in
[LiteRT-LM#3508](https://github.com/google-ai-edge/LiteRT-LM/issues/3508).
An NPU bundle is compiled for one KV-cache length: 4096 for every Gemma 4 E2B
NPU build, 1280 for Gemma 3 1B and FastVLM, 4096 for Gemma 3 270M (the
catalog's `requiredMaxTokens`, and the context the
[Model Registry](/docs/registry) gives each NPU build). `maxTokens` is **not**
clamped up to 1024 on the NPU attempt (it is on CPU and GPU — see below); keep
it at or below that length. Only a bundle compiled
for an NPU runs on one. A generic bundle is never tried there: it has no NPU
graph, and LiteRT would try to compile it on the device with a compiler
plugin, which no NPU stack here ships, and run it on the CPU while reporting
`npu` (measured on a Galaxy
S24), so `npu` falls back to GPU and then CPU for it, and the floor applies to
those attempts. A bundle compiled for an NPU runs only on Windows, on Android
phones with Qualcomm FastRPC, on Qualcomm Linux arm64 boards that pass the
FastRPC checks above, and on Google Tensor G5/G6 Pixels with Android 16 or
later, not a `BP2A` build — the last three only when the app sets `qualcomm_npu` or
`google_tensor_npu`;
anywhere else it is refused, because nothing there can run it (on macOS the
native runtime was measured accepting `npu` anyway, which made `activeBackend`
report an NPU that does not exist on the machine). On Windows the check is per
OS, so a PC without an Intel NPU still attempts it.

</Warning>

### Where a model runs

Before it creates an engine, the native engine reads the bundle's header and
the compiler stamp of each compiled section — a few hundred bytes each, tens of
milliseconds for a 3 GB file — and decides from them:

| The file | No `preferredBackend` | `preferredBackend` given |
|---|---|---|
| A generic bundle | GPU, then CPU | `gpu` / `cpu`: that backend, then the next; `npu`: not tried, since the bundle has no NPU graph (GPU, then CPU, with a notice; refused with `backendFallback: false`) |
| A text model declaring `backend_constraint` | the first of GPU, CPU it allows | only the backends it declares, the NPU only when the bundle is compiled for one (a file that declares only the NPU and is not is refused) |
| A bundle compiled for an NPU (`…_qualcomm_sm8750.litertlm`, …) | the NPU | `npu`: the NPU; `gpu` / `cpu`: refused |
| A file shorter than its sections | refused: the download is incomplete | refused |
| A `.litertlm` the reader cannot read (a newer container version, a malformed header) | GPU, then CPU | the request, then the fallback order, `npu` included: the rules from before the reader |

An encoder left unset (`preferredVisionBackend`, `preferredAudioBackend`) runs
where the file says: its declared `backend_constraint` (CPU when that allows
it), the NPU when its section is compiled for one, else CPU. The official
`…_qualcomm_sm8750` and `…_qualcomm_qcs8275` bundles, whose encoders are not
compiled for the NPU, run them on the CPU; a bundle with compiled encoders runs
them on the NPU, and only with its text model on the NPU too: an NPU encoder
next to a text model on the GPU or the CPU is refused when it is on
(`unsupportedNpu`). Asking an encoder for a backend its `backend_constraint`
excludes — the GPU for the published Gemma 4 and Gemma 3n audio encoders,
which declare cpu — is refused. `model.activeVisionBackend` and
`model.activeAudioBackend` report the choice (null for a bundle without that
encoder). A refusal is a `LiteRtLmBundleException` whose `problem`
says why (`incomplete`, `wrongBackend`, `unsupportedNpu` for a MediaTek bundle,
a Qualcomm one on Windows or a Google Tensor one off Android), thrown before any engine
exists. The device's SoC is not read up front: a bundle built for another
Qualcomm SoC fails at engine create, and the error names the SoC it was built
for.

### One attempt, with the reason

By default a load that fails on its backend tries the next one.
`LiteRtLmEngine(backendFallback: false)` makes one attempt — on
`preferredBackend`, or, when none is given, on the GPU (the NPU for a bundle
compiled for one, the first backend a constrained text model allows) — and
throws a
`BackendInitException` whose one attempt carries LiteRT-LM's own reason, read
from its C API on every platform and in release builds:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: [const LiteRtLmEngine(backendFallback: false)],
);
try {
  await FlutterEdgeAi.getActiveModel(preferredBackend: PreferredBackend.gpu);
} on BackendInitException catch (e) {
  final error = e.lastAttempt.error;
  print('did not load on ${e.lastAttempt.backend.name}: '
      '${error is LiteRtLmEngineCreateException ? error.nativeMessage : error}');
}
```

An NPU the device cannot reach is refused before any engine exists, and so is a
bundle compiled for an NPU there, with or without the flag.

### Inspecting a model file

`readLiteRtLmBundleInfo(path)` (native only) returns what the engine reads:

```dart
final info = await readLiteRtLmBundleInfo(path);
info.isComplete;               // false for a download that stopped early
info.isCompiledForNpu;         // runs on the NPU only
info.npuTarget;                // e.g. Qualcomm SM8750, or null
info.visionEncoder?.npuTarget; // null: the encoder is not compiled
info.audioEncoder?.backendConstraint; // e.g. ['cpu']
info.hasMtpDrafter;            // can decode speculatively
```

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
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/+esm');
  window.Engine = m.Engine;
  window.EmbeddingEngine = m.EmbeddingEngine;
  return m.Engine;
})();
</script>
```

`window.EmbeddingEngine` (1.13.1) is what EmbeddingGemma 2 embedders run on in
the browser, on WebGPU — text and images, and from 1.13.2 audio and combined
inputs. A page without it fails the
embedder's load with an `EmbeddingLoadException` naming the line, and so does a
browser without WebGPU: there is no CPU fallback, because the CPU (WebAssembly)
path of `@litert-lm/core` 0.18.0 cannot read these bundles' external weights.
An LLM and an embedder on the same page share one WebAssembly module and one
WebGPU device, and take turns: an embedding waits while a reply is being
generated, and a reply waits for an embedding in progress. The module has 4 GB
of memory, and the 440m's vision encoder does not fit in it next to Gemma 4
E2B (measured): whichever loads second fails. Close the LLM before loading the
440m with images, or embed text only — the 270m, or the 440m without images,
loads next to the LLM.

Native platforms need no web setup.

## See also

- [Desktop Support](/docs/desktop) — the FFI path on macOS / Windows / Linux.
- [Embeddings & RAG](/docs/embeddings-and-rag) — the `LiteRtEmbeddingBackend` this package ships.
- [Packages](/docs/packages) — the full opt-in package matrix and APIs.
