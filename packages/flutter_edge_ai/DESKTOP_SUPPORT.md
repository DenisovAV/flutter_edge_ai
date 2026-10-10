# Flutter Edge AI Desktop Support

Detailed setup and reference for running Flutter Edge AI on **macOS, Windows, and Linux**.

> **FFI architecture**: desktop platforms run LiteRT-LM **directly via `dart:ffi`**. The previous Kotlin/JVM gRPC server (`litertlm-server.jar` + Azul Zulu JRE) is gone — no Java required, no separate process, no IPC overhead. Engine startup is ~2 s instead of ~10–15 s.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Supported Platforms](#supported-platforms)
3. [Requirements](#requirements)
4. [Quick Start](#quick-start)
5. [Platform-Specific Setup](#platform-specific-setup)
6. [Model Lifecycle](#model-lifecycle)
7. [Known Limitations](#known-limitations)
8. [Troubleshooting](#troubleshooting)

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│              Flutter Desktop App                     │
│                                                      │
│   ┌──────────────────────────────────────────────┐ │
│   │  FlutterEdgeAiDesktop (lib/desktop/)           │ │
│   │           ↓                                    │ │
│   │  LiteRtLmFfiClient                            │ │
│   │  (flutter_edge_ai_litertlm/lib/src/ffi/)        │ │
│   │           ↓ dart:ffi                           │ │
│   │  ───────────────────────────────────           │ │
│   │  libLiteRtLm.{dylib,dll,so}                    │ │
│   │  + libLiteRt.{dll,so} (Linux/Windows)          │ │
│   │  + libLiteRtLmMetalAccelerator.dylib (macOS)   │ │
│   │  + libLiteRtWebGpuAccelerator.{dll,so}         │ │
│   │  + libwebgpu_dawn.{dll,so} (Linux/Windows GPU) │ │
│   │  + dxil.dll + dxcompiler.dll (Windows GPU)     │ │
│   └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

**Native libraries** are fetched at build time by `hook/build.dart` from the
GitHub release `native-v0.18.0-d`, SHA256-verified, and bundled by Flutter
[Native Assets](https://docs.flutter.dev/development/platform-integration/c-interop)
into the application bundle. End-users only need to add a small
`post_install` snippet to their **macOS** `Podfile` so the upstream companion
dylibs get wrapped into `.framework` bundles (and re-signed) inside the app's
`Contents/Frameworks/` for LiteRT-LM's `gpu_registry` to find them — see
[macOS setup in the README](README.md#macos) for the exact block.
Linux and Windows are fully self-contained (no manual setup).

The Dart FFI layer is shared with mobile — Android and iOS use the same
`LiteRtLmFfiClient` against the same C API. Only the dynamic library
loading sequence differs per platform (handled in `litert_lm_client.dart`).

> **⚠️ Model format**
>
> The LiteRT-LM engine accepts only `.litertlm` files; MediaPipe `.bin` / `.task`
> models used on web won't load on desktop. ONNX Runtime (`flutter_edge_ai_onnx`)
> also runs on all three desktops, and built-in AI on macOS and Windows. See
> [litert-community on Hugging Face](https://huggingface.co/litert-community) for compatible `.litertlm` models.

---

## Supported Platforms

| Platform | Architecture | GPU backend | Vision | Audio | Notes |
|----------|--------------|-------------|--------|-------|-------|
| macOS | arm64 (Apple Silicon) | Metal | ✅ | ✅ | Vision verified on Gemma 4 + Gemma 3n via Metal |
| macOS | x86_64 | — | — | — | Not supported (Apple Silicon only) |
| Windows | x86_64 | DirectX 12 (via Dawn/WebGPU) | ✅ | ✅ | Nothing to install |
| Windows | arm64 | — | — | — | Not supported |
| Linux | x86_64 | Vulkan (via Dawn/WebGPU) | ✅ | ✅ | glibc ≥ 2.34 (Ubuntu 22.04+, Debian 12+, RHEL 9+) |
| Linux | arm64 | Vulkan (via Dawn/WebGPU) | ✅ | ✅ | Same glibc requirement |

> Qualcomm Linux arm64 boards also run `PreferredBackend.npu` on the Hexagon DSP when the app opts in with `qualcomm_npu: true` — see the [`flutter_edge_ai_litertlm` README](../flutter_edge_ai_litertlm/README.md).

For mobile platforms see the main [README](README.md).

---

## Requirements

- **Flutter** ≥ 3.44.0
- **Dart SDK** ≥ 3.12.0
- **macOS**: 11+ (Apple Silicon, arm64); 12.0 with `flutter_edge_ai_builtin_ai`
- **Windows**: 10/11 64-bit. No Visual C++ Redistributable needed since `flutter_gemma_litertlm` 1.7.1 (see below).
- **Linux**: glibc ≥ 2.34, libstdc++ ≥ 6.0.30 (Ubuntu 22.04+, Debian 12+, Fedora 36+, RHEL 9+)
- **GPU drivers**: any vendor driver with WebGPU/Vulkan/Metal/DX12 support; falls back to CPU if not available

No Java/JVM/JRE required.

---

## Quick Start

```yaml
# pubspec.yaml
dependencies:
  flutter_edge_ai: ^2.2.0            # core
  flutter_edge_ai_litertlm: ^1.12.0  # .litertlm engine
```

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

Future<void> chat() async {
  // Register the LiteRT-LM engine (it takes .litertlm files only).
  await FlutterEdgeAi.initialize(inferenceEngines: const [LiteRtLmEngine()]);

  // Install model (downloads on first run, cached after). Gemma 4 from
  // litert-community is public — no token needed.
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  ).fromNetwork(
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
  ).install();

  // Create model with full capabilities — keep it for the app's lifetime.
  final model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 4096,
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: true,
  );

  // Each chat / conversation is a session. Sessions are cheap to create
  // and destroy; the engine is reused across them.
  // Sampling left unset: the model's own sampler, else its family's defaults.
  final session = await model.createSession();
  await session.addQueryChunk(Message(text: 'Hi!', isUser: true));
  await for (final chunk in session.getResponseAsync()) {
    print(chunk);
  }
  await session.close();
}
```

For the high-level chat API with history + thinking + tool calling, use
`model.createChat(...)` and `chat.generateChatResponseAsync()`. See
[`example/`](example/) for a complete app.

---

## Platform-Specific Setup

### macOS

Native libs are fetched and bundled automatically via Native Assets. The
**only manual step** is adding a `post_install` block to your app's
`macos/Podfile` so the upstream companion dylibs get wrapped into
`.framework` bundles (and re-signed) inside `Contents/Frameworks/`, and
`LiteRtLm.dylib`'s `LC_LOAD_DYLIB` reference is re-pointed at the new
framework path (LiteRT-LM's `gpu_registry` resolves the Metal accelerator
through that framework). See the
[macOS setup snippet in the README](README.md#macos) for the exact
block. Without it the companion dylibs are never bundled, and
`LiteRtLm.dylib` — which links `libGemmaModelConstraintProvider.dylib`
directly — fails to load on every backend, CPU included.

**Entitlements** in both `macos/Runner/DebugProfile.entitlements` and
`Release.entitlements`, beside the `com.apple.security.app-sandbox` key that
`flutter create` already writes:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

`network.client` lets the sandboxed app download a model.
`disable-library-validation` takes effect once Hardened Runtime is on, which
notarization requires: the build phase signs LiteRT-LM and its companion
libraries ad hoc, and library validation refuses code not signed by Apple or by
the app's own team.

Do not add the iOS `com.apple.developer.kernel.*` memory entitlements — they are
iOS-only. Without a signing team the build fails with `"Runner" has entitlements
that require signing with a development certificate`, and a team-signed build
drops them. A `.litertlm` model loads on macOS without them.

### Windows

`flutter_edge_ai_litertlm` bundles every required DLL — no manual setup. The
bundle includes:

- `LiteRtLm.dll`, `LiteRt.dll`, `libGemmaModelConstraintProvider.dll`, `StreamProxy.dll`
- `libLiteRtWebGpuAccelerator.dll`, `libLiteRtTopKWebGpuSampler.dll`
- `webgpu_dawn.dll` (Dawn WebGPU backend — split into a shared lib in LiteRT-LM v0.14.0; the accelerator DLL imports it, so GPU fails without it)
- `dxil.dll` + `dxcompiler.dll` (DirectX Shader Compiler runtime — required for WebGPU/DX12 shader compilation; sourced from
  [microsoft/DirectXShaderCompiler v1.9.2602](https://github.com/microsoft/DirectXShaderCompiler/releases/tag/v1.9.2602))
- `LiteRtDispatch.dll`, the OpenVINO runtime (`openvino*.dll`) and TBB (`tbb*.dll`) — the Intel NPU dispatch behind `PreferredBackend.npu` on Lunar Lake / Panther Lake

Most companion DLLs ship under two names (`LiteRt.dll` and `libLiteRt.dll`, and
so on): Native Assets drops the `lib` prefix on Windows, while `LiteRtLm.dll`
imports them with it.

`StreamProxy.dll` exposes a `LoadLibraryExA(LOAD_WITH_ALTERED_SEARCH_PATH)`
helper that the plugin uses to pre-load `LiteRt.dll`,
`libLiteRtTopKWebGpuSampler.dll` and `libLiteRtWebGpuAccelerator.dll`, then
`LiteRtLm.dll` itself. Without
this, modern Windows DLL search order doesn't always include the application
directory for secondary `LoadLibrary` calls made by `gpu_registry.cc` /
`sampler_factory.cc` at runtime — they would fail to find the GPU accelerator
DLL and silently fall back to CPU. (Mirrors the Linux `RTLD_GLOBAL` pattern.)

Your end-users need nothing installed. Since `flutter_gemma_litertlm` 1.7.1
`LiteRtLm.dll` is linked against the static CRT and imports no C++ runtime at all;
measured on `native-v0.18.0`, 16 of its 24 DLLs import none.

The other eight are the Intel NPU stack behind `PreferredBackend.npu`: our own
`LiteRtDispatch.dll`, which links OpenVINO's C++ API and keeps the dynamic CRT, plus
Intel's three `openvino*` and four `tbb*`. Each imports some of `msvcp140`,
`vcruntime140` and `vcruntime140_1` — the runtimes any Flutter Windows app already
resolves — and none imports `vcruntime140_threads.dll`, the Visual Studio 2022 17.8
one that used to make this document ask for a redistributable and that failed a Microsoft
Store certification VM ([#456](https://github.com/DenisovAV/flutter_edge_ai/issues/456)).
Nothing statically imports `LiteRtDispatch.dll` either, and `litert_dispatch_lib_dir`
is set only for that backend, so an app that never asks for the Intel NPU never loads
them at all.

### Linux

The bundle includes:

- `libLiteRtLm.so`, `libLiteRt.so`, `libGemmaModelConstraintProvider.so`
- `libLiteRtWebGpuAccelerator.so`, `libLiteRtTopKWebGpuSampler.so`, `libStreamProxy.so`
- `libwebgpu_dawn.so` (Dawn WebGPU backend — split into a shared lib in LiteRT-LM v0.14.0; the accelerator loads it via `$ORIGIN` rpath, so GPU fails without it)

`libStreamProxy.so` is a tiny helper that exposes `stream_proxy_load_global`
(an `RTLD_GLOBAL` `dlopen`). The plugin uses it to pre-load `libLiteRt.so`
before `libLiteRtLm.so` so the WebGPU accelerator's runtime
`dlsym(RTLD_DEFAULT, "LiteRt*")` resolves — without `RTLD_GLOBAL` Dart's
default `RTLD_LOCAL` would hide the symbols. The Windows variant of the
same helper (`StreamProxy.dll` → `LoadLibraryExA`) plays the equivalent
role on Windows; macOS dyld auto-resolves by basename so no helper is
needed there.

Linux GPU uses Dawn/WebGPU on top of Vulkan, so you need a working Vulkan
driver. On NVIDIA install the proprietary driver; on Intel/AMD the open-source
Mesa driver works out of the box on most distros.

For headless / server-side use (no display), `Xvfb` is enough as a fake
display surrogate — Flutter Linux integration tests run that way.

---

## Model Lifecycle

This applies to all desktop platforms; understanding it avoids the most
common runtime issues.

### One model, many sessions

The recommended (and only well-supported) pattern is:

```dart
// At app startup, ONCE:
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  preferredBackend: PreferredBackend.gpu,
  supportImage: true,
  supportAudio: true,
);

// During app runtime, MANY TIMES:
final session = await model.createSession(...);
// ... chat, generate, etc.
await session.close();   // cheap

// At app shutdown:
await model.close();
```

Sessions are cheap to create/destroy. The expensive part is `engine_create`
(2–10 s depending on backend and model size), which happens once when the
model is first opened.

### Why not "one model per chat"?

Upstream LiteRT-LM keeps `LiteRtEnvironment` as a **process singleton** for
GPU paths (see comment in `runtime/core/engine_impl.cc` referencing `b/454383477`).
Once the env is initialized with the first model's settings — `cache_dir`,
backend, capabilities — those become process-fixed. Trying to recreate the
engine with different settings results in conflicts in the GPU stack
(notably a `wgpu::Instance already set` from the WebGpu sampler binary on
Linux/Windows).

The plugin avoids this by:

1. Reusing the same `InferenceModel` whenever requested params match (built-in singleton in `FlutterEdgeAiDesktop.createModel`).
2. Disabling GPU sampler preload on Linux so the upstream sampler factory falls back to a CPU sampler — eliminates the `wgpu::Instance` conflict and re-enables runtime model swap on Linux GPU.

If you do need to swap models at runtime, call `model.close()` first, then
`getActiveModel(...)` again with the new active model's spec. On Linux, this
works thanks to the CPU-sampler fallback above; on macOS it works because
per-token sampling already runs on CPU there. Windows preloads the GPU sampler
(see Known Limitations below), so a model swap on Windows GPU is unverified.

### Switching backend (CPU ↔ GPU)

Same as switching model — close, then reopen with the new `preferredBackend`.

---

## Known Limitations

### Windows discrete GPU (historical)

`flutter_gemma_litertlm` 1.2.0–1.3.1 crashed on Windows **discrete GPUs**: the
Windows build passed a Bazel define upstream had removed, so the LiteRt runtime
was linked statically and conflicted with the separately shipped WebGPU
accelerator. Fixed in 1.4.0, before the rename — every
`flutter_edge_ai_litertlm` release has the fix.

### Per-token sampler: GPU on Windows, CPU on macOS and Linux

When `preferredBackend: PreferredBackend.gpu`, the **forward pass** (prefill +
decode) runs on the GPU accelerator (Metal, DX12, Vulkan). Where the
**per-token sampler** (top-k / top-p / argmax) runs depends on the platform; on
CPU it costs roughly 1–5 ms per token, small next to the forward pass.

- **Windows** — GPU. The plugin preloads `libLiteRtTopKWebGpuSampler.dll`,
  which in `native-v0.18.0` exports its full C ABI (7 of 7 functions; the
  3-of-7 prebuilt of [#2073](https://github.com/google-ai-edge/LiteRT-LM/issues/2073)
  is gone).
- **macOS** — CPU. The bundle does not ship `libLiteRtTopKMetalSampler`:
  upstream opens it by bare file name, which cannot reach a library inside the
  app bundle, so the factory uses the CPU chain.
- **Linux** — CPU. The sampler `.so` exports its full C ABI, but the prebuilt
  `libLiteRtTopKWebGpuSampler.so` holds a
  process-static `wgpu::Instance` that any second `engine_create` rejects with
  `ALREADY_EXISTS: wgpu::Instance already set`. Since runtime model swap is
  more important than the few ms saved by GPU sampling, the plugin
  intentionally does not preload the sampler `.so` and lets the factory fall
  back to CPU.
  - [google-ai-edge/LiteRT #3133](https://github.com/google-ai-edge/LiteRT/issues/3133) — "MLDrift fails running second model" (closed; upstream confirms env singleton is intentional)
  - [google-ai-edge/LiteRT-LM #966](https://github.com/google-ai-edge/LiteRT-LM/issues/966) — community ask for the one-engine-many-sessions pattern

Once upstream lands a wgpu reset API, the plugin can preload the sampler on
Linux too.

### `randomSeed` / `temperature` / `topK` / `topP` — only the first session's values apply

**Only the first generation on an engine sets the sampler.** Every later session
on that same engine keeps those values, whatever it asks for. This is an
upstream defect ([LiteRT-LM #2080](https://github.com/google-ai-edge/LiteRT-LM/issues/2080),
open) and it reproduces on every version we have measured — v0.14.0, v0.15.0 and
v0.16.0 on CPU as well as GPU, and v0.17.0 (checked on CPU).

So the common shape is: an app loads a model, runs one generation with the
defaults (the model's own sampler, else its family's), and from then on the
engine keeps them — a later `temperature: 1.5` changes nothing, and a later
`topK: 1` will not give you argmax. Since `flutter_edge_ai_litertlm` 1.12.0 a
warning is printed, once per loaded model, when a later session's values
differ and either set was chosen by the caller.

The seed is not re-applied either. The sampler keeps its RNG state across
sessions, so two byte-identical requests on one engine produce different text.

**Workaround:** close and recreate the engine when you need different sampler
settings. `model.close()` followed by `FlutterEdgeAi.getActiveModel(...)` gives a
fresh engine that honors its first session, at the cost of a model reload. If
your app uses one fixed configuration throughout — as most chat apps do — this
never surfaces, because the first session already set the values you wanted.

> Before litertlm 1.2.0 we carried a build-time patch
> (`native/litert_lm/patch_c_api.sh`, offered upstream as
> [PR #2081](https://github.com/google-ai-edge/LiteRT-LM/pull/2081)) that fixed
> this downstream. v0.14.0 added a native session-config sampler API, so the
> patch was dropped — but the underlying baking was not fixed, although this
> section claimed otherwise for a while from 2026-07-23. The repros live in
> `example/integration_test/sampler_baking_2080_test.dart` and
> `sampler_reverse_probe_test.dart`.

Reproducer: `flutter test integration_test/regression_bugs_test.dart` on any
platform — `randomSeed=42` vs `randomSeed=99` at `temperature=1.0`.

### Audio modality requires LiteRT-LM models

Audio input only works with `.litertlm` models that include the audio adapter
(Gemma 3n E2B/E4B, Gemma 4 E2B/E4B). MediaPipe `.task` models on web don't
support audio.

### iOS Simulator: GPU disabled

iOS Simulator's Metal has a 256 MB single-allocation cap that LLM weight
tensors exceed (Gemma 3 1B's KV cache alone is 288 MB). Use CPU on the
simulator, or test on a physical iPhone for GPU validation.

---

## Troubleshooting

### Engine create fails with no native log on Linux

In **debug builds** `flutter_edge_ai_litertlm` redirects native stderr to
`<tmpdir>/litertlm_native.log` and dumps it via `debugPrint` after a failed
`engine_create`. If you don't see a dump, make sure the app runs as a debug
build (`flutter run --debug`).

In release builds stderr goes to systemd journal / app's own stderr — check
your distribution's log facility.

### `glibc 2.38 not found` on Linux

The current bundle is built against glibc 2.34 (Ubuntu 22.04 toolchain). If
you see this error on a stock Ubuntu 22.04 system you're loading a stale copy
from the build cache. Clear it and let the hook re-fetch the release:

```bash
rm -rf ~/.cache/flutter_gemma/native
flutter clean && flutter run
```

Working on the package itself? A local `native/litert_lm/prebuilt/linux_x86_64/`
takes precedence over the release without saying so — delete that too.

`hook/build.dart` will fetch the correct glibc-2.34 binary from the GitHub
release on next run.

### Windows GPU shaders fail to compile

Symptom: `engine_create` returns null with no Dart-side error, app silently
falls back to CPU.

Verify `dxcompiler.dll` and `dxil.dll` are next to your `app.exe`. They should
be — Native Assets bundles them. If they're absent, the WebGPU/DX12 shader
compiler can't run.

If they're present but still failing, it is not a missing Visual C++ runtime —
neither DLL imports one. Look at the GPU driver instead.

### Model file not found / `Cannot find: gemma-...litertlm`

On desktop the model is downloaded to a `flutter_gemma/` folder outside
`Documents/` (the folder keeps that name across the rename):

- macOS: `~/Library/Application Support/<bundle-id>/flutter_gemma/` (`getApplicationSupportDirectory()`;
  a sandboxed app: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/<bundle-id>/flutter_gemma/`)
- Windows: `%LOCALAPPDATA%\flutter_gemma\`
- Linux: `~/.local/share/<app-id>/flutter_gemma/` (`getApplicationSupportDirectory()`)

Use `FlutterEdgeAi.installModel(...).fromNetwork(...).install()` to download,
or `.fromFile(absolutePath)` if you already have it locally.

### Pre-cached engine + new code = stale cache

LiteRT-LM caches compiled GPU shaders in the app's support directory (what
`getApplicationSupportDirectory()` returns — not the `flutter_gemma/` folder the
model sits in), as `<model>.litertlm_<mtime>_<size>_mldrift_program_cache.bin`.
The name is keyed on the model file's timestamp and size, so a new model build
gets a fresh cache by itself (the old file stays behind). After upgrading the
plugin, delete the file and the engine rebuilds the cache on first run.

---

## API Reference

`FlutterEdgeAi`, `InferenceModel`, `InferenceModelSession`, `InferenceChat` —
all platform-agnostic. See `lib/flutter_edge_ai_interface.dart` and the
[example app](example/) for usage patterns.

For native debugging on iOS / Linux, see comments in
`flutter_edge_ai_litertlm/lib/src/ffi/litert_lm_client.dart` (search for `stream_proxy_redirect_stderr`
and `_dumpNativeLog`).
