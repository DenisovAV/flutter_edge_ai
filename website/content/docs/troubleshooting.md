---
title: Troubleshooting
description: Common issues — downloads, memory, iOS simulator GPU, Android minSdk, web caching, and desktop storage.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

Common issues and fixes. For desktop-specific problems (Linux native logs,
glibc, Windows DXC, stale GPU shader cache) see
[Desktop Support → Troubleshooting](/docs/desktop#troubleshooting).

## Downloads

- **Resume isn't supported by the HuggingFace CDN.** flutter_edge_ai uses smart retry with exponential backoff and **automatic restart** of interrupted downloads instead. Tune the attempt count via `maxDownloadRetries` in `FlutterEdgeAi.initialize(...)` (default: 10).
- **Large downloads on Android** need `foreground: true` to get a foreground service (which shows a notification) and bypass Android's 9-minute background execution limit. The default (`null`) does not configure a notification, and without one the platform never starts the service — so the size threshold alone does nothing. iOS uses native URLSession and needs no special handling. See [Models → downloads](/docs/models#android-foreground-service-large-downloads).
- **Using `background_downloader` in your own app too?** flutter_edge_ai no longer listens to `FileDownloader().updates` (fixed in `flutter_gemma` 1.6.3). That stream takes a single subscription, so claiming it made every later `FileDownloader().updates.listen(...)` in the host app throw *"Stream has already been listened to"*. Updates are now scoped to flutter_edge_ai's own task group and the stream stays yours.
- **Custom servers on Web** must enable CORS headers. HuggingFace is already configured correctly; for Firebase Storage see the [CORS configuration docs](https://firebase.google.com/docs/storage/web/download-files#cors_configuration).

### Gated models / download errors (401, 403)

`installModel(...).install()` throws a public `DownloadException` carrying a sealed `DownloadError`, so you can react to gated HuggingFace models (HTTP 401/403) by **type** instead of substring-matching error strings:

```dart
try {
  await FlutterEdgeAi.installModel(modelType: ModelType.gemmaIt)
      .fromNetwork(url, token: hfToken)
      .install();
} on DownloadException catch (e) {
  switch (e.error) {
    case UnauthorizedError():   // 401 — missing/invalid HuggingFace token
    case ForbiddenError():      // 403 — token lacks access to this gated model
      showGatedModelDialog();
    case NotFoundError():       // 404 — bad URL (use /resolve/main/, not /blob/main/)
      showNotFoundDialog();
    case RateLimitedError():    // 429
    case ServerError():         // 5xx
    case NetworkError():        // connectivity
    case CanceledError():       // user canceled
    case UnknownError():
      showRetryDialog(e.error.toUserMessage());
  }
}
```

For a **gated** model (401/403): pass a valid `huggingFaceToken` to `FlutterEdgeAi.initialize(...)` (or `token:` on `fromNetwork(...)`), open the model page on HuggingFace, accept its license, and request access. Each `DownloadError` also exposes `toUserMessage()`, `toTitle()`, `isRetryable`, and `requiresUserAction` for building UI.

<Info>

Auth errors (401/403/404) fail fast after one attempt — they are not retried. Only `NetworkError`, `ServerError`, and `RateLimitedError` are retryable (see `isRetryable`).

</Info>

## Memory

- **iOS:** ensure `Runner.entitlements` contains the memory entitlements and the deployment target is at least 15.0 (16.0 with `flutter_edge_ai_mediapipe`) — in Xcode on the Runner target under SPM, or in the `Podfile` when one exists. See [Installation → iOS](/docs/installation#ios).
- Reduce `maxTokens` if you hit memory pressure — but **keep it at 1024 or higher for `.litertlm` models** (see "maxTokens vs maxOutputTokens" below). To shorten replies, use `maxOutputTokens`, not a smaller `maxTokens`.
- Use smaller models (1B-2B parameters) for devices with <6GB RAM. Multimodal models (Gemma 4, Gemma3n) need 8GB+.
- Close sessions and models when not needed; monitor usage with `sizeInTokens()`.
- To see what a model actually costs, measure the memory the OS cannot reclaim before and after loading it with [`flutter_edge_ai_diagnostics`](/docs/diagnostics) (Android + iOS). The RSS a profiler shows also counts mmapped weights the OS can drop, so it does not show that cost.

## maxTokens vs maxOutputTokens

`maxTokens` (on `getActiveModel`/`createModel`) is the **context window** — the total budget shared by the input (system prompt + history + your message) **and** the generated output (the KV-cache size). It is **not** the reply length.

`.litertlm` models require a context window of at least **1024**. Passing a smaller `maxTokens` (e.g. `100`) used to crash with `DYNAMIC_UPDATE_SLICE failed to prepare` / `Failed to allocate tensors` (even on CPU — the failure is at graph compile, before the backend runs). As of **`flutter_gemma_litertlm` 1.0.2** a too-small `maxTokens` is clamped up to 1024 automatically with a log warning — except on `PreferredBackend.npu`, where the context is baked into the compiled bundle (see [NPU](#npu)).

To limit how many tokens the model **generates**, use `maxOutputTokens` on `createSession`/`openSession`/`createChat`/`openChat` instead:

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024); // context window
final chat = await model.createChat(maxOutputTokens: 100);        // reply cap
```

(`maxOutputTokens` is honored on `.litertlm` and ONNX; the MediaPipe `.task` path has no session-level output cap and ignores it.)

## iOS

- **Build issues:** ensure the minimum iOS version is at least 15.0 (16.0 with `flutter_edge_ai_mediapipe`). If the app has a `Podfile` (any app using `flutter_edge_ai_mediapipe` does — it ships no `Package.swift`), also use static linking (`use_frameworks! :linkage => :static`) and reinstall with `cd ios && pod install --repo-update`. An SPM-only app has no `Podfile`; there the deployment target lives on the Runner target in Xcode.
- **Simulator GPU disabled:** iOS Simulator's Metal has a 256 MB single-allocation cap that LLM weight tensors exceed (e.g. Gemma 3 1B's KV cache alone is 288 MB). Use CPU on the simulator, or test GPU on a physical iPhone. This is a simulator limit, not a plugin bug.

## Android

- **`.litertlm` models require minSdk 30.** `libLiteRtLm.so` depends on API 30+ Bionic syscalls (`pthread_cond_clockwait`, `sem_clockwait`) that can't be shimmed on older devices. MediaPipe `.task` models work on lower API levels.
- **`.litertlm` / embeddings / vision are `arm64-v8a` only.** MediaPipe text inference (`.task` / `.bin`) also runs on `x86_64` and `armeabi-v7a`. If you only use arm64-only features, add `ndk { abiFilters 'arm64-v8a' }` (in `build.gradle.kts`: `ndk { abiFilters += listOf("arm64-v8a") }`) so the Play Store doesn't offer broken APKs. See [Installation → Android architecture](/docs/installation#android-architecture-support).
- **GPU:** nothing to add — the OpenCL `<uses-native-library>` entries come from the core plugin's own manifest (`flutter_gemma` 1.2.0+) through the manifest merger. If the GPU backend still falls back, check that the merged manifest contains `libvndksupport.so` and `libOpenCL.so`. See [Installation → Android](/docs/installation#android).
- **Google Play rejects the release: "Your app does not support 16 KB memory page sizes".** Fixed in `flutter_gemma_litertlm` 1.8.0; every `flutter_edge_ai_litertlm` release includes the fix. Nothing fails at build or run time — the rejection happens at submission. The Qualcomm Hexagon DSP blobs of the NPU path (`libQnnHtpV{73,75,79,81}Skel.so`) come from Qualcomm with a 4 KB `p_align`, and Play scans `lib/**/*.so` without caring that a Hexagon image is loaded by the DSP rather than mapped by the kernel. Since 1.10.0 they ship only in apps that set `qualcomm_npu: true`, and the build hook raises them to 16 KB. Check your own build with Google’s `check_elf_alignment.sh` against the APK. See [#529](https://github.com/DenisovAV/flutter_edge_ai/issues/529).
- **GPU backend crashes at `engine_create` on Mali GPUs (`SIGSEGV`, `pc 0` in `libLiteRtOpenClAccelerator.so`).** Fixed in `flutter_gemma_litertlm` 1.8.2; every `flutter_edge_ai_litertlm` release includes the fix. In 1.7.0–1.8.1 the OpenCL and GPU accelerators called `AHardwareBuffer_allocate` without declaring `libandroid.so`, so Android bound the call to address 0; only Mali GPUs (Samsung A-series, MediaTek, Google Tensor) take that path, so CPU and Adreno were unaffected. See [#545](https://github.com/DenisovAV/flutter_edge_ai/issues/545).
- **Zero chunks and `Stream error: <U+FFFD>`, then `SIGABRT`.** Fixed in `flutter_gemma_litertlm` 1.5.2; every `flutter_edge_ai_litertlm` release includes the fix. On Android the first `dlopen` of `libLiteRtLm` decides for the whole process whether its symbols are reachable from the default search scope, and bionic never promotes it afterwards — so an app that embedded or transcribed anything before its first generation left the stream-callback ABI probe blind and the wrong callback shape was registered. If your own or third-party code loads `libLiteRtLm` first, load it with `RTLD_GLOBAL` — the package cannot repair that case, but it raises a `StateError` naming it rather than generating corrupt text. See [#447](https://github.com/DenisovAV/flutter_edge_ai/issues/447).

## Web

- **MediaPipe is GPU-only on web.** The web engine ignores `preferredBackend` and always runs on the browser's GPU (WebGPU). ONNX on web is the exception: `PreferredBackend.cpu` pins WASM there.
- **Mobile `.task` models often don't work on web** — use the `-web.task` (MediaPipe) or `.litertlm` (LiteRT-LM) web variant.
- **Memory / cache limits:**

| Browser | Max Model Size | Notes |
|---|---|---|
| **Chrome/Firefox** | ~2 GB | ArrayBuffer limit |
| **Safari** | ~50 MB | ⚠️ Not suitable |

- **Large models (>2GB):** use `WebStorageMode.streaming` (OPFS) to bypass the ~2 GB blob limit. Check support with `await FlutterEdgeAi.isStreamingSupported()`. See [Installation → web storage](/docs/installation#2-initialize-flutter-edge-ai).
- **Storage modes:** `cacheApi` (default, persists across restarts, <2GB), `streaming` (OPFS, large models, requires Chrome 86+/Edge 86+/Safari 15.2+), `none` (ephemeral, testing only).

### Web `.litertlm` (early preview) feature matrix

Web `.litertlm` inference runs `.litertlm` models in the browser via the
upstream [`@litert-lm/core`](https://www.npmjs.com/package/@litert-lm/core)
package (WebGPU + WASM). It is an **early preview** and a subset of the native
path. MediaPipe `.task` on web is unaffected and remains fully supported.

**Works on web `.litertlm`:** text generation (sync + streaming), multi-turn chat
with history, system instruction, **function calling / tool calls** (Gemma 4),
**thinking mode** (Gemma 4 measured in Chrome; Qwen3 `<think>` tags parsed by
core), concurrent sessions (serialized), large models via OPFS streaming.

**Not supported on web `.litertlm` yet (mobile/desktop only):**

- ❌ **Vision / image input** — image inputs are dropped with a debug warning.
- ❌ **Audio input** — no Audio executor config in the JS API.
- ❌ **LoRA weights** — `loraPath` throws `UnsupportedError`.

<Info>

For vision on Web today, use a compatible MediaPipe `.task` build. Neither Web
engine supports audio. These Web `.litertlm` limits track the upstream
`@litert-lm/core` early-preview API and will lift as Google extends the JS
executor surface.

</Info>

## Windows desktop GPU crashes

<Warning>

**Historical.** Windows **discrete GPUs** crashed on `PreferredBackend.gpu` in
`flutter_gemma_litertlm` 1.2.0–1.3.1, fixed in 1.4.0 — before the rename, so
every `flutter_edge_ai_litertlm` release has the fix. macOS/Linux GPU and
Windows CPU/NPU were never affected. See [Desktop → Known
limitations](/docs/desktop#known-limitations).

</Warning>

## Wrong numbers on GPU

**Gemma 4 copies digits wrongly out of a long prompt on some GPUs**, the same
way on every run: asked when a delivery arrived (`2026/06/23`), it answers
`20226/12/17`. It shows from about 2,000 prompt tokens, on Metal and on Adreno.
The published Gemma 4 `.litertlm` files ask for half-precision activations;
ask for full precision instead:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  preferredBackend: PreferredBackend.gpu,
  activationDataType: ActivationDataType.float32,
);
```

Prefill gets slower (about 3× on a Snapdragon 8 Elite and an iPhone 11, under
1.5× on an Apple M3 Max); decode speed barely changes. Upstream:
[LiteRT-LM#3012](https://github.com/google-ai-edge/LiteRT-LM/issues/3012) (Adreno),
[LiteRT-LM#2814](https://github.com/google-ai-edge/LiteRT-LM/issues/2814) (Metal).

**Not on web.** The web engine ignores `activationDataType` — it has no such
setting — and so do MediaPipe, ONNX and built-in AI. On the engines that read
it, it reaches the text decoder only: the vision and audio encoders keep the
type the model file asks for.

Every `flutter_edge_ai_litertlm` release applies it (it arrived in
`flutter_gemma_litertlm` 1.8.3; older versions accepted the argument and
ignored it).

On Android the GPU shares system memory, so on a 4–6 GB phone running out of it
at `float32` can end the app rather than fall back to CPU. Both precisions share
one compiled GPU program cache per model, so switching recompiles the GPU
programs (about 600 MB for Gemma 4 E2B): pick one precision per install rather
than per request.

`float32` activations also need more GPU memory than `float16`. If the GPU
engine cannot be created the model falls back to CPU **without an error** — the
digits are then right and the model is far slower, which is easy to mistake for
the fix working. Read the backend the model actually got:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  preferredBackend: PreferredBackend.gpu,
  activationDataType: ActivationDataType.float32,
);
if (model.activeBackend != PreferredBackend.gpu) {
  // CPU fallback: right digits, but not the run you asked for.
}
```

## Windows embeddings and speech fail with status 3

<Warning>

**Fixed in litertlm 1.7.0.** On Windows, embeddings and on-device speech
(STT/TTS) fail with `LiteRT call failed: CreateTensorBufferFromHostMemory(...)
(status=3)` in litertlm 1.4.0–1.6.4. Fixed in `flutter_gemma_litertlm` 1.7.0 and
`flutter_gemma_speech` 0.5.1, so every `flutter_edge_ai_*` release has it. Text generation and the other platforms
were never affected.

</Warning>

## NPU

**The model answers, fluently, about the beginning of a long prompt and ignores
the rest.** That is the Gemma 3 family on an NPU. Nothing raises, nothing is
logged: every prefill chunk after the first is dropped, so the model genuinely
never saw the end of your prompt. On Qualcomm it is a size threshold in the
compiled bundle's prefill mask (~1 MiB; at prefill 128 the largest working
`cache_length` for the 4-head Gemma 3 bundles is 896, and every published
`qualcomm.*` Gemma 3 bundle is built above it); on Intel it happens regardless
of size, through a different defect. Run a **Gemma 4** bundle on the NPU, or move
that model to `PreferredBackend.cpu` / `.gpu`. Upstream:
[LiteRT-LM#3508](https://github.com/google-ai-edge/LiteRT-LM/issues/3508).

Note that `maxTokens` is **not** clamped up to 1024 on the NPU attempt the way
it is on CPU and GPU — the safe context is baked into the compiled bundle, so
pass the `cache_length` it was built for. If the NPU fails to initialize the
engine falls back to GPU and then CPU, and the floor applies to those attempts,
so the fallback is clamped rather than crashed.

**`PreferredBackend.npu` on Android falls back to GPU after an upgrade.** From
`flutter_edge_ai_litertlm` 1.10.0 the Qualcomm QNN runtime is not part of the
package; the app opts in with `qualcomm_npu: true` under `hooks: user_defines:
flutter_edge_ai_litertlm:` in its pubspec — see [LiteRT-LM](/docs/litertlm). The
log names the reason. If it says the stack is not enabled although the flag is
set, the flag is in the wrong pubspec: in a pub workspace only the workspace
root's `user_defines` count. If the build fails fetching `qnn-runtime`, the
machine cannot reach Maven Central; set `qualcomm_npu_maven_url` to a mirror or
`qualcomm_npu_aar` to a local copy of the same AAR.

**`PreferredBackend.npu` on a Qualcomm Linux board falls back to GPU.** The
same `qualcomm_npu: true` covers Linux arm64 builds. The log names which of
these is missing:
- The build did not bundle the stack — the flag is not set, or not in the
  workspace root's pubspec.
- `/dev/fastrpc-cdsp` does not exist — the board exposes no compute DSP.
- It, or `/dev/dma_heap/system`, is not accessible — add the user to group
  `fastrpc` (`sudo usermod -aG fastrpc $USER`) and log in again.
- `libcdsprpc.so.1` does not open — install Qualcomm's FastRPC
  (`qcom-fastrpc1` on Ubuntu).

If the build fails reading the QAIRT SDK, the machine cannot reach
`softwarecenter.qualcomm.com`; download `v2.50.0.260828.zip` elsewhere and set
`qualcomm_npu_qairt_zip` to its path. Do not set `DSP_LIBRARY_PATH`: FastRPC
prefers it over `ADSP_LIBRARY_PATH`, which is where the bundled Skels are
announced.

**`PreferredBackend.npu` is unavailable on a recent Snapdragon.** SoC coverage is
the runtime's, not ours: Snapdragon 8 Gen 5 (**SM8845** — OnePlus 15R, iQOO 15R
and the like) is not covered upstream, and a context compiled for SM8850 is
rejected by an SM8845 device even though both are Hexagon v81. Tracked at
[LiteRT#7516](https://github.com/google-ai-edge/LiteRT/issues/7516); note the
easily-confused naming — 8s Gen 4 is SM8735, not SM8845.

## Desktop storage locations

Desktop builds store downloaded models **outside** the user's `Documents/` folder
to avoid OneDrive / iCloud / Domain-Roaming sync corrupting FFI mmap of large
`.litertlm` files:

- **Windows:** `%LOCALAPPDATA%\flutter_gemma\` (never OneDrive-synced)
- **macOS:** `~/Library/Application Support/<bundle>/flutter_gemma/`
- **Linux:** `~/.local/share/<app>/flutter_gemma/`

The directory keeps its `flutter_gemma` name across the rename, so installed models stay found.

Models installed by older 0.14.x / 0.15.0 builds that still live under
`Documents/` keep working via a fallback read.

On Windows, flutter_gemma **before 1.4.0** could write a *fresh* download to a
`$CWD`-relative path (`<cwd>\Users\…\AppData\Local\flutter_gemma\`) instead of the
absolute `%LOCALAPPDATA%\flutter_gemma\`, because `%LOCALAPPDATA%` is not one of
`background_downloader`'s base directories. The model then reported "installed"
but failed to load with *"model file paths not found"*. **Fixed in 1.4.0** — it
affected every fresh inference / embedding / STT download on Windows, so upgrade
if you hit it.

## Multimodal

- Ensure you're using a multimodal model (Gemma 4, Gemma3n E2B/E4B, FastVLM, Qwen2-VL, SmolVLM2, LLaVA-OneVision).
- Set `supportImage: true` (and `supportAudio: true` for audio) when creating the model.
- Check device memory — multimodal models require more RAM.
- **Image input crashes at model load on a GPU text backend (older releases).**
  On Metal (iOS/macOS) and WebGPU (Windows/Linux) the vision encoder's ops can't
  be prepared by the GPU delegate. Fixed in **`flutter_gemma_litertlm` 1.4.2 /
  core 1.5.9** — the vision encoder now defaults to CPU while the text decoder
  keeps the GPU. Upgrade if you hit it.
- Use the GPU backend for faster text decoding. Image encoding runs on CPU by
  default; move audio encoding to GPU with `preferredAudioBackend: PreferredBackend.gpu`.
  To force GPU vision (only for a model built to allow it), pass
  `preferredVisionBackend: PreferredBackend.gpu`. See [Multimodal](/docs/multimodal).

## Native libraries fetched at build time

Some packages download their native library from a GitHub Release when you first
build for a platform, then cache it under `~/.cache/flutter_gemma/native/`
(`~/Library/Caches/…` on macOS, `%LOCALAPPDATA%\…` on Windows). This applies to
`flutter_edge_ai_litertlm` (always has), `flutter_edge_ai_onnx`, and
`flutter_edge_ai_sqlite` (every release; as `flutter_gemma_rag_sqlite` from
1.3.0 — before that it shipped the loadables inside the package).

- **The build fails with a download error or an HTTP status.** The first build of
  each platform needs `github.com` reachable. In an air-gapped or proxied CI,
  copy the whole `flutter_gemma/native` cache directory from a machine that
  built the same package versions, including its hidden version-marker files —
  a folder copied without them is discarded and fetched again. There is no
  setting that points the build at archives you vendor yourself.
- **The build fails with `CHECKSUM MISMATCH`.** The bytes served do not match
  what the package version was pinned to. Re-run once to rule out a corrupt
  transfer. If it persists, the release asset was replaced after publication —
  do not work around it by clearing the checksum; report it.
- **A build that used to succeed now fails instead of quietly skipping.** That is
  deliberate. These hooks used to report success while bundling nothing, which
  surfaced later as an opaque `dlopen` crash on a user's device. A platform the
  package claims to support now fails the build when its library cannot be
  produced.
- **Maintainers only:** a local `native/<name>/prebuilt/<target>/` overrides the
  pinned release. `flutter_edge_ai_sqlite` says so on stderr when it takes that
  path; `flutter_edge_ai_litertlm` and `flutter_edge_ai_onnx` take it silently. If a
  new release "did not take", look for that directory first.

## Embeddings

- **`StateError: No embedding tokenizer is configured`** on the first embedding. Since `flutter_gemma` 1.9.0 an embedding backend no longer carries a tokenizer: which family a model needs (Gemma SentencePiece, BERT WordPiece) is a property of the model, not of the engine that runs it, so the app registers it once. Add `flutter_edge_ai_embeddings` to `pubspec.yaml`, import it, and pass `embeddingTokenizers: [GemmaEmbeddingTokenizers()]` to `FlutterEdgeAi.initialize()` beside `embeddingBackends:`. The error text names the package and the parameter. See [Embeddings & RAG](/docs/embeddings-and-rag).
- **On the old `flutter_gemma_*` packages: `Target of URI doesn't exist: package:flutter_gemma_embeddings/web_embedding_model.dart`** at `flutter build web`. `flutter_gemma_embeddings` 2.2.0 moved that file into `flutter_gemma_litertlm` 1.8.0, alongside the rest of the LiteRT.js bundle it belongs to. A lockfile holding `flutter_gemma_litertlm` at 1.7.x while `flutter_gemma_embeddings` moves to 2.2.0 resolves cleanly and only then fails to compile. Upgrade `flutter_gemma_litertlm` to 1.8.0. Native builds are unaffected — that import sits behind a web-only conditional export.

## Function calling

- Function calling is supported by Gemma 4, Gemma3n E4B (`.litertlm` build), FunctionGemma, DeepSeek, Qwen and Phi-4 Mini. If you pass `tools` with `supportsFunctionCalls: false`, the chat logs a warning and does not inject them — the model still works for text generation. Pass `supportsFunctionCalls: true` for models that support it. See [Function Calling](/docs/function-calling).
