---
title: Desktop Support
description: Setup and reference for running flutter_edge_ai on macOS, Windows, and Linux via dart:ffi.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

Detailed setup and reference for running flutter_edge_ai on **macOS, Windows, and
Linux**. Desktop platforms run LiteRT-LM **directly via `dart:ffi`** — no
Kotlin/JVM gRPC server, no Java required, no separate process, no IPC overhead.
Engine startup is ~2 s instead of ~10–15 s.

LiteRT-LM (`.litertlm`) is the **primary, default** desktop engine — but not the
only one. **`flutter_edge_ai_onnx`** ([ONNX Runtime](/docs/onnx) — ORT-GenAI
generation + ORT embeddings) also runs on all three desktop OSes
(macOS/Windows/Linux), and the OS built-in model is available through
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

**Native libraries** are fetched at build time by the package's `hook/build.dart`
from the GitHub release, SHA256-verified, and bundled by Flutter
[Native Assets](https://docs.flutter.dev/development/platform-integration/c-interop)
into the application bundle. The Dart FFI layer is shared with mobile — Android
and iOS use the same `LiteRtLmFfiClient` against the same C API. Only the dynamic
library loading sequence differs per platform.

<Warning>

**Model format (LiteRT-LM engine):** the LiteRT-LM engine on desktop accepts only
`.litertlm` files. MediaPipe `.bin` / `.task` models used on web won't load on
desktop. See [litert-community on Hugging Face](https://huggingface.co/litert-community)
for compatible models. (The [ONNX engine](/docs/onnx) uses its own `.onnx` model
directories instead.)

</Warning>

## Supported platforms

| Platform | Architecture | GPU backend | Vision | Audio | Notes |
|---|---|---|---|---|---|
| macOS | arm64 (Apple Silicon) | Metal | ✅ | ✅ | Vision verified on Gemma 4 + Gemma 3n (text decoder on Metal, vision encoder on CPU) |
| macOS | x86_64 | — | — | — | Not supported (Apple Silicon only) |
| Windows | x86_64 | DirectX 12 (via Dawn/WebGPU) | ✅ | ✅ | Nothing to install |
| Windows | arm64 | — | — | — | Not supported |
| Linux | x86_64 | Vulkan (via Dawn/WebGPU) | ✅ | ✅ | glibc ≥ 2.34 (Ubuntu 22.04+, Debian 12+, RHEL 9+) |
| Linux | arm64 | Vulkan (via Dawn/WebGPU) | ✅ | ✅ | Same glibc requirement |

<Warning>

**Fixed in litertlm 1.4.0.** On litertlm 1.2.0–1.3.1, Windows **discrete GPUs**
crash on `PreferredBackend.gpu`. Upgrade to 1.4.0; on the affected versions use
`PreferredBackend.cpu` or `.npu`. macOS/Linux GPU and Windows CPU/NPU were
never affected.

</Warning>

<Info>

**Windows NPU.** `PreferredBackend.npu` on Windows requires **Intel
LunarLake/PantherLake** silicon — the Windows native archive ships
`LiteRtDispatch.dll` + the OpenVino runtime + TBB to drive it. On any other
Windows hardware the NPU backend is unavailable; use `PreferredBackend.gpu` or
`.cpu`.

Run **Gemma 4** there. On the Intel NPU a Gemma 3 bundle loses every prefill
chunk after the first — the reply is fluent, answers from the opening of your
prompt and never mentions the rest, with no error raised
([LiteRT-LM#3508](https://github.com/google-ai-edge/LiteRT-LM/issues/3508)).

</Info>

## Requirements

- **Flutter** ≥ 3.44.0
- **macOS**: Apple Silicon (arm64)
- **Windows**: 10/11 64-bit. No Visual C++ Redistributable needed since `flutter_gemma_litertlm` 1.7.1 (see below).
- **Linux**: glibc ≥ 2.34, libstdc++ ≥ 6.0.30 (Ubuntu 22.04+, Debian 12+, Fedora 36+, RHEL 9+)
- **GPU drivers**: any vendor driver with WebGPU/Vulkan/Metal/DX12 support; falls back to CPU if not available

No Java/JVM/JRE required.

## Quick Start

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

Future<void> chat() async {
  // Install model (downloads on first run, cached after).
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  ).fromNetwork(
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    token: 'hf_...',
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
  final session = await model.createSession(temperature: 0.8, topK: 1);
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

2. Replace that Podfile's `post_install` block with the one below; the next
   build runs `pod install` itself.

A green build proves nothing: without the block the first model load fails with
`Library not loaded: @rpath/libGemmaModelConstraintProvider.dylib`. If the app already has a `macos/Podfile` (another plugin needs
CocoaPods), keep SPM on and just paste the block. Use the pubspec setting rather
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
  # flutter_gemma_litertlm and is delivered next to the dylibs it stages. That
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
          echo "  flutter_gemma_litertlm 1.6.2+ installs it there from its build hook." >&2
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
that the plugin uses to pre-load `LiteRt.dll`, `libLiteRtTopKWebGpuSampler.dll`
and `libLiteRtWebGpuAccelerator.dll`, then `LiteRtLm.dll` itself. Without this,
modern Windows DLL search order doesn't always include the application directory
for secondary `LoadLibrary` calls — they would fail to find the GPU accelerator
DLL and silently fall back to CPU.

End-users need nothing installed. Since `flutter_gemma_litertlm` 1.7.1
`LiteRtLm.dll` is linked against the static CRT and imports no C++ runtime at all;
measured on `native-v0.18.0`, 16 of its 24 DLLs import none.

The other eight are the Intel NPU stack behind `PreferredBackend.npu`: our own
`LiteRtDispatch.dll`, which links OpenVINO's C++ API and keeps the dynamic CRT, plus
Intel's three `openvino*` and four `tbb*`. Each imports some of `msvcp140`,
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
`dlopen`). The plugin uses it to pre-load `libLiteRt.so` before `libLiteRtLm.so`
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

The recommended (and only well-supported) pattern:

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

### Why not "one model per chat"?

Upstream LiteRT-LM keeps `LiteRtEnvironment` as a **process singleton** for GPU
paths. Once the env is initialized with the first model's settings (`cache_dir`,
backend, capabilities), those become process-fixed. Recreating the engine with
different settings causes GPU-stack conflicts (notably `wgpu::Instance already set`
from the WebGpu sampler binary on Linux/Windows).

The plugin avoids this by reusing the same `InferenceModel` when params match, and
by disabling GPU sampler preload on Linux (CPU-sampler fallback) so runtime model
swap works. To swap models at runtime, call `model.close()` first, then
`getActiveModel(...)` again. Switching backend (CPU ↔ GPU) works the same way.

## Known limitations

### Windows discrete GPU crashes (litertlm 1.2.0–1.3.1) — fixed in 1.4.0

Windows **discrete GPUs** crash on `PreferredBackend.gpu` in litertlm
1.2.0–1.3.1. The Windows native build passed a Bazel define that upstream had
removed, so it silently linked the LiteRt runtime statically — which conflicts
with the separately shipped WebGPU accelerator once Dawn was split out into its
own library. The define was corrected in 1.4.0 and Windows GPU works again.

On 1.2.0–1.3.1 use `PreferredBackend.cpu` or `.npu`. macOS/Linux GPU and
Windows CPU/NPU were never affected.

### Per-token sampler: GPU on Windows, CPU on macOS and Linux

When `preferredBackend: PreferredBackend.gpu`, the **forward pass** (prefill +
decode) runs on the GPU accelerator (Metal, DX12, Vulkan). Where the **per-token
sampler** (top-k / top-p / argmax) runs depends on the platform; on CPU it costs
roughly 1–5 ms per token, small next to the forward pass. The **vision
encoder** runs on CPU by default (the GPU delegate can't prepare its ops);
override per-encoder with `preferredVisionBackend:` / `preferredAudioBackend:`
on `getActiveModel(...)`.

- **Windows** — GPU. The plugin preloads `libLiteRtTopKWebGpuSampler.dll`, which in `native-v0.17.1` exports its full C ABI (7 of 7 functions).
- **macOS** — CPU. The bundle does not ship `libLiteRtTopKMetalSampler`: upstream opens it by bare file name, which cannot reach a library inside the app bundle, so the factory uses the CPU chain.
- **Linux** — CPU. The sampler `.so` exports its full C ABI, but it holds a process-static `wgpu::Instance` that any second `engine_create` rejects. Since runtime model swap matters more than the few ms saved, the plugin doesn't preload it and lets the factory fall back to CPU.

### `randomSeed` / `temperature` / `topK` / `topP` — only the first session's values apply

<Warning>

**Only the first generation on an engine sets the sampler.** Every later session
on that same engine keeps those values, whatever it asks for. Upstream defect
([LiteRT-LM #2080](https://github.com/google-ai-edge/LiteRT-LM/issues/2080),
open), reproducing on v0.14.0, v0.15.0 and v0.16.0 on CPU as well as GPU, and on
v0.17.0 (checked on CPU).

</Warning>

`topK` defaults to `1`, which is greedy — so the common shape is: an app loads a
model, runs one generation with defaults, and from then on the engine is locked
greedy. A later `temperature: 1.5` changes nothing, with no error and no warning.
It runs the other way too: an engine whose first session is stochastic keeps
sampling, and a later `topK: 1` will not give you argmax. The seed is not
re-applied either — the sampler keeps its RNG state across sessions, so two
identical requests on one engine produce different text.

**Workaround:** close and recreate the engine when you need different sampler
settings — `model.close()` then `FlutterEdgeAi.getActiveModel(...)` — at the cost
of a model reload. If your app uses one fixed configuration throughout, as most
chat apps do, this never surfaces: the first session already set the values you
wanted.

Before litertlm 1.2.0 we carried a build-time patch that fixed this downstream
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

In **debug builds** the plugin redirects native stderr to
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

<Warning>

On a Windows **discrete GPU** with litertlm 1.2.0–1.3.1, GPU also crashes for a
separate reason — a Bazel define we passed had been removed upstream, so the
runtime linked statically. Fixed in 1.4.0. See
[Known limitations](#known-limitations).

</Warning>

### Model file not found

On desktop the model is downloaded to the platform's standard "app support"
directory (see [Troubleshooting → desktop storage](/docs/troubleshooting)). Use
`FlutterEdgeAi.installModel(...).fromNetwork(...).install()` to download, or
`.fromFile(absolutePath)` if you already have it locally.

### Pre-cached engine + new code = stale cache

LiteRT-LM caches compiled GPU shaders in the app's support directory (what
`getApplicationSupportDirectory()` returns — not the `flutter_gemma/` folder the
model sits in), as `<model>.litertlm_<mtime>_<size>_mldrift_program_cache.bin`.
The name is keyed on the model file's timestamp and size, so a new model build
gets a fresh cache by itself (the old file stays behind). After upgrading the
plugin, delete the file and the engine rebuilds the cache on first run.
