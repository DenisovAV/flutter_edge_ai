---
title: Desktop Support
description: Setup and reference for running flutter_edge_ai on macOS, Windows, and Linux via dart:ffi.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

Detailed setup and reference for running flutter_edge_ai on **macOS, Windows, and
Linux**. Desktop platforms run LiteRT-LM **directly via `dart:ffi`** — no Java,
no separate process, no IPC.

LiteRT-LM (`.litertlm`) is the **primary** desktop engine (core registers no
engine, so register `LiteRtLmEngine()`), but not the only one. **`flutter_edge_ai_onnx`** ([ONNX Runtime](/docs/onnx) — ORT-GenAI
generation + ORT embeddings) also runs on desktop (macOS arm64, Linux x64 and
Windows x64), **`flutter_edge_ai_llama`** ([llama.cpp](/docs/llama), `.gguf`)
runs on all three desktops, and the OS built-in model is available through
**`flutter_edge_ai_builtin_ai`** ([Built-in AI](/docs/builtin-ai)) on **macOS**
(Apple Foundation Models) and, since 0.3.0, on **Windows** (AI Foundry / Phi
Silica — nothing to configure to build: `flutter_local_ai` resolves the Windows
App SDK projection itself; running needs Windows 11 25H2+ on Copilot+-class
hardware and a packaged app).
Linux has no OS built-in model. What holds across all of desktop is the narrower
statement: **there is no MediaPipe engine on desktop.** See
[Installation](/docs/installation) and [Packages](/docs/packages).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│              Flutter Desktop App                     │
│                                                      │
│   ┌──────────────────────────────────────────────┐ │
│   │  FlutterEdgeAiDesktop (lib/src/desktop/)       │ │
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

**Native libraries** are fetched at build time by the package's `hook/build.dart`
from the GitHub release, SHA256-verified, and bundled by Flutter
[Native Assets](https://docs.flutter.dev/development/platform-integration/c-interop)
into the application bundle. The Dart FFI layer is shared with mobile — Android
and iOS use the same `LiteRtLmFfiClient` against the same C API. Only the dynamic
library loading sequence differs per platform.

<Warning>

**Model format (LiteRT-LM engine):** the LiteRT-LM engine on desktop accepts only
`.litertlm` files. MediaPipe `.bin` / `.task` models used on web won't load on
desktop. Any `.litertlm` model works; see [Models](/docs/models). (The
[ONNX engine](/docs/onnx) uses its own `.onnx` model directories instead.)

</Warning>

## Supported platforms

| Platform | Architecture | GPU backend | Vision | Audio | Notes |
|---|---|---|---|---|---|
| macOS | arm64 (Apple Silicon) | Metal | ✅ | ✅ | Vision verified on Gemma 4 + Gemma 3n (text decoder on Metal; the vision encoder runs where the bundle says: CPU on Gemma 4, GPU on Gemma 3n) |
| macOS | x86_64 | — | — | — | Not supported (Apple Silicon only) |
| Windows | x86_64 | DirectX 12 (via Dawn/WebGPU) | ✅ | ✅ | Nothing to install |
| Windows | arm64 | — | — | — | Not supported |
| Linux | x86_64 | Vulkan (via Dawn/WebGPU) | ✅ | ✅ | glibc ≥ 2.34, libstdc++ ≥ 6.0.30 (Ubuntu 22.04+, Debian 12+, RHEL 10+; RHEL 9 ships GCC 11's older libstdc++) |
| Linux | arm64 | Vulkan (via Dawn/WebGPU) | ✅ | ✅ | Same glibc and libstdc++ requirement |

Qualcomm Linux arm64 boards also run `PreferredBackend.npu` on the Hexagon DSP
when the app opts in with `qualcomm_npu: true` — see
[LiteRT-LM](/docs/litertlm).

<Info>

**Windows NPU.** `PreferredBackend.npu` on Windows requires **Intel
LunarLake/PantherLake** silicon — the Windows native archive ships
`LiteRtDispatch.dll` + the OpenVino runtime + TBB to drive it. Other Windows
hardware has no NPU to run on: use `PreferredBackend.gpu` or `.cpu`. The load
does not check for one — a bundle compiled for the Intel NPU is not refused on a
PC without it, and what LiteRT does then is not measured. LLMs on the Intel NPU
need `flutter_edge_ai_litertlm` 1.15.0: every release from
`flutter_gemma_litertlm` 1.7.0 (`native-v0.17.0`) through 1.14.0 failed the load
or ended the process with `0xC0000409`
([LiteRT-LM#4023](https://github.com/google-ai-edge/LiteRT-LM/issues/4023)).

Intel's Gemma 4 12B for Panther Lake needs `flutter_edge_ai_litertlm` 1.17.0:
its NPU blobs carry metadata 2.7, which the OpenVINO 2026.3 of earlier releases
refuses. 1.17.0 ships OpenVINO 2026.4.1. Measured with Intel NPU driver
32.0.100.4778 on both PCs.

A bundle whose NPU blobs carry no weights makes the dispatch copy them to
`%TEMP%\litert_ov_bank_<hex>.bin` at every load: 5.55 GB for Intel's 12B, 74.5
MB for EmbeddingGemma 2 270m `_Intel_PTL`. Keep that much free on the system
drive. The dispatch deletes the file when the model is closed, so an app that
exits without closing the model leaves it behind. From 1.17.0 each app marks
its banks with a `<bank>.<pid>.owner` file it keeps open while the model is
loaded. The next NPU load deletes the banks whose owner is gone, and the
unmarked ones written before the PC last started, and prints how much it freed.
Windows' Fast Startup shutdown does not count as a start. An unmarked bank
written since the start is kept, because an app on an older release or another
LiteRT program may still be using it.

Run **Gemma 4** there. On the Intel NPU a Gemma 3 bundle loses every prefill
chunk after the first — the reply is fluent, answers from the opening of your
prompt and never mentions the rest, with no error raised
([LiteRT-LM#3508](https://github.com/google-ai-edge/LiteRT-LM/issues/3508)).

EmbeddingGemma 2's Panther Lake bundles (`…_Intel_PTL.litertlm`) run on the
same stack from `flutter_edge_ai_litertlm` 1.13.2:
see [EmbeddingGemma 2 on an Intel NPU](/docs/embeddings-and-rag#embeddinggemma-2-on-an-intel-npu).

</Info>

## Requirements

- **Flutter** ≥ 3.44.0
- **macOS**: Apple Silicon (arm64); 12.0 with `flutter_edge_ai_builtin_ai`, 14.0 with `flutter_edge_ai_llama`
- **Windows**: 10/11 64-bit. LiteRT-LM needs no Visual C++ Redistributable (see below); `flutter_edge_ai_llama` does — llamadart needs the matching Visual C++ runtime.
- **Linux**: glibc ≥ 2.34, libstdc++ ≥ 6.0.30 (Ubuntu 22.04+, Debian 12+, Fedora 36+, RHEL 10+ — RHEL 9 ships GCC 11's libstdc++, which is too old)
- **GPU drivers**: any vendor driver with WebGPU/Vulkan/Metal/DX12 support; falls back to CPU if not available (`LiteRtLmEngine(backendFallback: false)` turns the fallback off)

No Java/JVM/JRE required.

## Quick Start

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

Future<void> chat() async {
  // Once, in main(): core has no engine of its own.
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
`model.createChat(...)` and `chat.generateChatResponseAsync()`.

## Platform-specific setup

### macOS

Native libs are fetched and bundled automatically via Native Assets — except
the Apple companion libraries, which an Xcode build phase stages. That phase is
installed by a `post_install` block in your app's `macos/Podfile`, so
the upstream companion dylibs get wrapped into `.framework` bundles (and
re-signed) inside `Contents/Frameworks/`, and `LiteRtLm.dylib`'s `LC_LOAD_DYLIB`
reference is re-pointed at the new framework path (LiteRT-LM's `gpu_registry`
resolves the Metal accelerator through that framework). Without it the
companion dylibs are never bundled, and `LiteRtLm.dylib` — which links
`libGemmaModelConstraintProvider.dylib` directly — fails to load on every
backend, CPU included.

Flutter 3.44+ uses Swift Package Manager by default, and an SPM-only app has no
`macos/Podfile`. So on macOS there are two steps:

1. Turn SPM off for the app in `pubspec.yaml`, then run `flutter pub get` (it
   writes `macos/Podfile`):

```
flutter:
  config:
    enable-swift-package-manager: false
```

2. Replace that Podfile's `post_install` block with the one below, keeping any
   lines of your own inside it; the next build runs `pod install` itself.

A green build proves nothing: without the block the first model load fails with
`Library not loaded: @rpath/libGemmaModelConstraintProvider.dylib`. If the app already has a `macos/Podfile` (another plugin needs
CocoaPods), keep SPM on and only replace its `post_install` block. Use the pubspec setting rather
than `flutter config --no-enable-swift-package-manager`, which changes only one
machine — not your teammates' or CI.

```
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_macos_build_settings(target)
  end

  # flutter_gemma: stage the upstream Apple companion dylibs into the built
  # .app. `hook/build.dart` deliberately skips them from Native Assets on macOS
  # (#247 — Google ships them without `-Wl,-headerpad_max_install_names`, so the
  # JIT bundling path cannot rewrite their install_name), which leaves this
  # build phase to stage them.
  #
  # The phase only LOCATES and RUNS a script; the staging logic itself lives in
  # flutter_edge_ai_litertlm and is delivered next to the dylibs it stages. That
  # is deliberate: this block is frozen into your Xcode project, and a copy of
  # the logic frozen there cannot be fixed by upgrading the package.
  installer.aggregate_targets.each do |aggregate_target|
    aggregate_target.user_targets.each do |user_target|
      phase_name = '[flutter_gemma] Setup LiteRT-LM macOS'

      # Only the app target embeds the Frameworks/ this phase patches.
      # RunnerTests inherits Runner's framework search paths and has no
      # Contents/Frameworks of its own — having the phase there creates a
      # cross-target dependency on Runner's framework output that Xcode reports
      # as "Cycle inside Flutter Assemble" (#300). Remove any stale copy from
      # non-app targets and skip them.
      unless user_target.name == 'Runner'
        user_target.build_phases
          .select { |p| p.respond_to?(:name) && p.name == phase_name }
          .each { |p| user_target.build_phases.delete(p) }
        next
      end

      existing = user_target.shell_script_build_phases.find { |p| p.name == phase_name }
      phase = existing || user_target.new_shell_script_build_phase(phase_name)
      # The embedded LiteRtLm binary is an INPUT so the phase re-runs whenever
      # Flutter's always-out-of-date `embed` phase re-copies the raw, unpatched
      # binary over the patched one. Without it Xcode caches the phase after the
      # first build and the second incremental build ships an unpatched
      # LiteRtLm that fails dlopen at runtime (#368).
      phase.input_paths = [
        '$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/Frameworks/LiteRtLm.framework/Versions/A/LiteRtLm',
      ]
      # A declared output lets Xcode order the phase in its dependency graph
      # instead of treating it as "runs every build with no outputs" — the other
      # half of the cycle warning (#300). The script touches this file.
      phase.output_paths = ['$(DERIVED_FILE_DIR)/flutter_gemma_litertlm_macos.stamp']
      phase.shell_script = <<~SHELL
        set -e
        STAGER="${HOME}/Library/Caches/flutter_gemma/native/macos_arm64/stage_macos_companions.sh"
        if [ ! -f "${STAGER}" ]; then
          echo "[flutter_gemma] ERROR: ${STAGER} not found." >&2
          echo "  flutter_edge_ai_litertlm installs it there from its build hook." >&2
          echo "  Upgrade the package, then: flutter clean && flutter pub get" >&2
          exit 1
        fi
        sh "${STAGER}" "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Frameworks"
        mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
        touch "${SCRIPT_OUTPUT_FILE_0}"
      SHELL
    end
  end
end
```

From Flutter 3.50 (a beta at the time of writing) a build with the setting off prints `Enabling Swift Package
Manager will be required in a future version of Flutter.`; the setting still
works. A route that needs no Podfile is tracked in
[#689](https://github.com/DenisovAV/flutter_edge_ai/issues/689).

**Entitlements** — add to both `macos/Runner/DebugProfile.entitlements` and
`Release.entitlements`:

```
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.app-sandbox</key>
<true/>
```

`network.client` lets the sandboxed app download a model.
`disable-library-validation` takes effect once Hardened Runtime is on, which
notarization requires: the build phase above signs LiteRT-LM and its companion
libraries ad hoc, and library validation refuses code not signed by Apple or by
the app's own team.

Do not add the iOS `com.apple.developer.kernel.*` memory entitlements — they are
iOS-only. Without a signing team the build fails with `"Runner" has entitlements
that require signing with a development certificate`, and a team-signed build
drops them. A `.litertlm` model loads on macOS without them.

### Windows

`flutter_edge_ai_litertlm` bundles every required DLL — no manual setup. The bundle
includes:

- `LiteRtLm.dll`, `LiteRt.dll`, `libGemmaModelConstraintProvider.dll`, `StreamProxy.dll`
- `libLiteRtWebGpuAccelerator.dll`, `libLiteRtTopKWebGpuSampler.dll`
- `webgpu_dawn.dll` (Dawn WebGPU backend — split into a shared lib in LiteRT-LM v0.14.0; the accelerator DLL imports it, so GPU fails without it)
- `dxil.dll` + `dxcompiler.dll` (DirectX Shader Compiler runtime — required for WebGPU/DX12 shader compilation; from [microsoft/DirectXShaderCompiler v1.9.2602](https://github.com/microsoft/DirectXShaderCompiler/releases/tag/v1.9.2602))
- `LiteRtDispatch.dll`, the OpenVINO runtime (`openvino*.dll`) and TBB (`tbb*.dll`) — the Intel NPU dispatch behind `PreferredBackend.npu` on Lunar Lake / Panther Lake

Most companion DLLs ship under two names (`LiteRt.dll` and `libLiteRt.dll`, and
so on): Native Assets drops the `lib` prefix on Windows, while `LiteRtLm.dll`
imports them with it.

`StreamProxy.dll` exposes a `LoadLibraryExA(LOAD_WITH_ALTERED_SEARCH_PATH)` helper
that `flutter_edge_ai_litertlm` uses to pre-load `LiteRt.dll`, `libLiteRtTopKWebGpuSampler.dll`
and `libLiteRtWebGpuAccelerator.dll`, then `LiteRtLm.dll` itself. Without this,
modern Windows DLL search order doesn't always include the application directory
for secondary `LoadLibrary` calls — they would fail to find the GPU accelerator
DLL and silently fall back to CPU.

End-users need nothing installed. `LiteRtLm.dll` is linked against the static CRT and imports no C++ runtime at all;
measured on `native-v0.18.0-g`, 17 of its 25 DLLs import none.

The other eight are the Intel NPU stack behind `PreferredBackend.npu`: our own
`LiteRtDispatch.dll`, which links OpenVINO's C++ API and keeps the dynamic CRT, plus
three of Intel's six `openvino*` (the NPU compiler, its loader and the NPU VM runtime import none)
and its four `tbb*`. Each imports some of `msvcp140`,
`vcruntime140` and `vcruntime140_1` — the runtimes any Flutter Windows app already
resolves — and none imports `vcruntime140_threads.dll`, the Visual Studio 2022 17.8
one that used to make this page ask for a redistributable and that failed a Microsoft
Store certification VM ([#456](https://github.com/DenisovAV/flutter_edge_ai/issues/456)).
Nothing statically imports `LiteRtDispatch.dll` either, and `litert_dispatch_lib_dir`
is set only for that backend, so an app that never asks for the Intel NPU never loads
them at all.

### Linux

The bundle includes:

- `libLiteRtLm.so`, `libLiteRt.so`, `libGemmaModelConstraintProvider.so`
- `libLiteRtWebGpuAccelerator.so`, `libLiteRtTopKWebGpuSampler.so`, `libStreamProxy.so`
- `libwebgpu_dawn.so` (Dawn WebGPU backend — split into a shared lib in LiteRT-LM v0.14.0; the accelerator loads it via `$ORIGIN` rpath, so GPU fails without it)

`libStreamProxy.so` exposes `stream_proxy_load_global` (an `RTLD_GLOBAL`
`dlopen`). `flutter_edge_ai_litertlm` uses it to pre-load `libLiteRt.so` before `libLiteRtLm.so`
so the WebGPU accelerator's runtime `dlsym(RTLD_DEFAULT, "LiteRt*")` resolves —
without `RTLD_GLOBAL`, Dart's default `RTLD_LOCAL` would hide the symbols.

Build dependencies:

```
sudo apt install clang cmake ninja-build libgtk-3-dev lld
```

Linux GPU uses Dawn/WebGPU on top of Vulkan, so you need a working vendor Vulkan
driver. On NVIDIA install the proprietary driver; on Intel/AMD the open-source
Mesa driver works on most distros.

```
sudo apt install vulkan-tools libvulkan1
# Plus your vendor driver, e.g. NVIDIA:
sudo apt install nvidia-driver-535-server
```

<Warning>

Mesa's `llvmpipe` software fallback caps `maxStorageBufferRange` at 128 MB, which
is below Gemma 4's per-buffer requirement — Gemma 4 will not run on `llvmpipe`.
Install a vendor driver before running on GPU. For headless / server-side use,
`Xvfb` is enough as a fake display surrogate.

</Warning>

## Model lifecycle

### One model, many sessions

The recommended pattern for one model:

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
(2–10 s depending on backend and model size), which happens once when the model is
first opened.

### Several models at once

`getActiveModel` gives the one active model: cached, and rebuilt (the previous
one closed) when a runtime parameter or the active model changes. To hold
several models at once, such as one file on CPU and on GPU, or two files, use
`FlutterEdgeAi.openModel` (`flutter_edge_ai` 2.5.0) with an engine that
supports it: `LiteRtLmEngine` (`flutter_edge_ai_litertlm` 1.16.0) on Android,
iOS and desktop.

```dart
final spec = (await FlutterEdgeAi.installModel(
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm,
).fromFile(path).install(activate: false)).spec;

final cpu = await FlutterEdgeAi.openModel(spec, preferredBackend: PreferredBackend.cpu);
final gpu = await FlutterEdgeAi.openModel(spec, preferredBackend: PreferredBackend.gpu);
// ... generate on either ...
await gpu.close();
await cpu.close();
```

- Each open model holds its own weights and KV cache, and the caller closes
  it: the plugin has no memory policy. On iOS a process past its memory limit
  is killed, with no exception to catch; read
  `FlutterEdgeAiDiagnostics.memorySnapshot()` (`flutter_edge_ai_diagnostics`)
  before opening another model.
- The models share the engine cache directory `getActiveModel` uses (the
  cache files of one model file serve every engine on it), the native
  libraries the process loaded, and LiteRT-LM's log level. Engine creations
  run one at a time; generation on open models does not wait for them.
- An opened model is never cached: a `getActiveModel` rebuild leaves it open,
  and closing it leaves the active model alone. Uninstalling a model does not
  close the models opened on it.
- `install(activate: false)` registers the file without making it the active
  model, and `openModel` takes the spec it returns. A model is its file name
  without the extension, so two files with the same name are one model; an
  `activate: false` install that would replace the active model's file throws
  a `StateError`.
- Measured on macOS (Apple silicon): CPU and GPU engines on one file, two GPU
  engines, and both created at the same time on an empty cache. On Windows
  Lunar Lake, CPU, GPU and NPU engines ran together in the Intel NPU demo
  (LiteRT-LM clients on `native-v0.18.0-f`). Not measured: Android, iOS,
  Linux, and two GPU engines on Windows, which preloads LiteRT-LM's WebGPU
  sampler: it keeps one `wgpu::Instance` per process, and a second one fails
  with `wgpu::Instance already set`.

To swap the active model, call `model.close()` first, then
`getActiveModel(...)` again. Switching its backend (CPU ↔ GPU) works the same way.

## Known limitations

### Windows discrete GPU (historical)

`flutter_gemma_litertlm` 1.2.0–1.3.1 crashed on Windows **discrete GPUs**: the
Windows build passed a Bazel define upstream had removed, so the LiteRt runtime
was linked statically and conflicted with the separately shipped WebGPU
accelerator. Fixed in 1.4.0, before the rename — every
`flutter_edge_ai_litertlm` release has the fix.

### Per-token sampler: GPU on Windows, CPU on macOS and Linux

When `preferredBackend: PreferredBackend.gpu`, the **forward pass** (prefill +
decode) runs on the GPU accelerator (Metal, DX12, Vulkan). Where the **per-token
sampler** (top-k / top-p / argmax) runs depends on the platform; on CPU it costs
roughly 1–5 ms per token, small next to the forward pass. An unset **vision
or audio encoder** backend follows the bundle — the section's
`backend_constraint`, else the NPU it is compiled for, else CPU (the GPU
delegate can't prepare the vision encoder's ops); set
`preferredVisionBackend:` / `preferredAudioBackend:` on `getActiveModel(...)`
only where the section allows it
(`(await readLiteRtLmBundleInfo(path)).audioEncoder?.backendConstraint`).

- **Windows** — GPU. `flutter_edge_ai_litertlm` preloads `libLiteRtTopKWebGpuSampler.dll`, which in `native-v0.18.0` exports its full C ABI (7 of 7 functions).
- **macOS** — CPU. The bundle does not ship `libLiteRtTopKMetalSampler`: upstream opens it by bare file name, which cannot reach a library inside the app bundle, so the factory uses the CPU chain.
- **Linux** — CPU. The sampler `.so` exports its full C ABI, but it holds a process-static `wgpu::Instance` that any second `engine_create` rejects. Since runtime model swap matters more than the few ms saved, `flutter_edge_ai_litertlm` doesn't preload it and lets the factory fall back to CPU.

### `randomSeed` / `temperature` / `topK` / `topP` — only the first session's values apply

<Warning>

**Only the first generation on an engine sets the sampler.** Every later session
on that same engine keeps those values, whatever it asks for. Upstream defect
([LiteRT-LM #2080](https://github.com/google-ai-edge/LiteRT-LM/issues/2080),
open), reproducing on v0.14.0, v0.15.0 and v0.16.0 on CPU as well as GPU, and on
v0.17.0 (checked on CPU) and v0.18.0 (macOS).

</Warning>

So the common shape is: an app loads a model, runs one generation with the
defaults (the model's own sampler, else its family's), and from then on the
engine keeps them. A later `temperature: 1.5` changes nothing, and a later
`topK: 1` will not give you argmax. Since `flutter_edge_ai_litertlm` 1.12.0 a
warning is printed, once per loaded model, when a later session's values
differ and either set was chosen by the caller. The seed is not
re-applied either — the sampler keeps its RNG state across sessions, so two
identical requests on one engine produce different text.

**Workaround:** close and recreate the engine when you need different sampler
settings — `model.close()` then `FlutterEdgeAi.getActiveModel(...)` — at the cost
of a model reload. If your app uses one fixed configuration throughout, as most
chat apps do, this never surfaces: the first session already set the values you
wanted.

Before `flutter_gemma_litertlm` 1.2.0 we carried a build-time patch that fixed this downstream
(offered upstream as [PR #2081](https://github.com/google-ai-edge/LiteRT-LM/pull/2081)).
v0.14.0 added a native session-config sampler API and the patch was dropped, but
the underlying baking was never fixed.

### Audio modality requires LiteRT-LM models

Audio input only works with `.litertlm` models that include the audio adapter
(Gemma 3n E2B/E4B, Gemma 4 E2B/E4B). See [Multimodal](/docs/multimodal).

### iOS Simulator: GPU disabled

iOS Simulator's Metal has a 256 MB single-allocation cap that LLM weight tensors
exceed. Use CPU on the simulator, or test on a physical iPhone for GPU validation.

## Troubleshooting

### Engine create fails with no native log on Linux

In **debug builds** `flutter_edge_ai_litertlm` redirects native stderr to
`<tmpdir>/litertlm_native.log` and dumps it via `debugPrint` after a failed
`engine_create`. In release builds stderr goes to the systemd journal / app's own
stderr.

### `glibc 2.38 not found` on Linux

The loaded `libLiteRtLm.so` was built against a newer glibc than your system
has. The released Linux bundle needs glibc 2.34, so this is a stale copy in the
build cache. Clear it and let `hook/build.dart` re-fetch the release:

```
rm -rf ~/.cache/flutter_gemma/native
flutter clean && flutter run
```

Working on the package itself? A local `native/litert_lm/prebuilt/linux_x86_64/`
takes precedence over the release without saying so — delete that too.

### Windows GPU shaders fail to compile

Symptom: `engine_create` returns null with no Dart-side error, app silently falls
back to CPU. Verify `dxcompiler.dll` and `dxil.dll` are next to your `app.exe`
(Native Assets bundles them). Neither imports the Visual C++ runtime, so a missing
redistributable is not the cause — look at the GPU driver instead.

### macOS: generation or embedding slows down while the app is in the background

App Nap throttles a backgrounded macOS app after about a minute, and on-device
models then run several times slower (measured: an EmbeddingGemma 2 image went
from 0.35 s to 2–7 s, with memory flat). An app that embeds or generates while
it is in the background should hold an activity for the duration of that work,
from its macOS runner:

```
let activity = ProcessInfo.processInfo.beginActivity(
  options: .userInitiated, reason: "Indexing photos")
// … the work …
ProcessInfo.processInfo.endActivity(activity)
```

An `NSAppSleepDisabled` key in `Info.plist` did not turn App Nap off in our
measurements; the activity does. The example app holds one for its whole
lifetime, because its integration tests run in the background.

### Model file not found

On desktop the model is downloaded to a `flutter_gemma/` folder in the
platform's standard "app support" directory on macOS and Linux, and in
`%LOCALAPPDATA%` on Windows (see [Troubleshooting → desktop storage](/docs/troubleshooting#desktop-storage-locations)). Use
`FlutterEdgeAi.installModel(...).fromNetwork(...).install()` to download, or
`.fromFile(absolutePath)` if you already have it locally.

### Pre-cached engine + new code = stale cache

LiteRT-LM caches compiled GPU shaders in the app's support directory (what
`getApplicationSupportDirectory()` returns — not the `flutter_gemma/` folder the
model sits in), as `<model>.litertlm_<mtime>_<size>_mldrift_program_cache.bin`.
The name is keyed on the model file's timestamp and size, so a new model build
gets a fresh cache by itself (the old file stays behind). After upgrading the
plugin, delete the file and the engine rebuilds the cache on first run.
