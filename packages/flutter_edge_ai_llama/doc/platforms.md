# Platform support

The connector provides GGUF inference through llamadart on Android, iOS, macOS,
Windows, Linux and Web. It requires Flutter 3.44+, Dart 3.12+ and core 2.5.0+ and published llamadart 0.15.1 with typed overflow reporting.
A passing build does not qualify every device, model or accelerator.

Version 0.0.5 pairs llamadart 0.15.1 with Apple
companion `llamadart_llama_cpp_flutter` 0.15.0. Published 0.0.2 pairs SDK
0.15.0 with companion 0.15.0; 0.0.1 paired 0.13.1 with 0.13.0.

| Feature | Native | Web |
| --- | --- | --- |
| GGUF text, independent chats and cancellation | Supported; inference shares one serialized runtime | Supported through the bridge worker |
| CPU | Supported | Supported through Wasm |
| GPU | Depends on the selected backend and device | Depends on browser WebGPU and runtime capabilities |
| Tools and thinking | Compatible model/template required | Compatible model/template/grammar required |
| Images and audio | Compatible app-owned projector required | Compatible projector and bridge capabilities required |
| LoRA | Installed adapter loads with the model; temporary session overrides are serialized | This connector does not wire Web adapters; it rejects installed or session adapters |
| GGUF embeddings | EmbeddingGemma 2 text; see per-platform status below | Unavailable |
| OPFS stream model handles | Not applicable | Unsupported; use cacheApi or network URLs |
| NPU, separate encoder backends, LiteRT activation/MTP and MediaPipe LoRA ranks | Unsupported by this connector | Unsupported |

Core restores the paired native adapter after restart. A missing adapter prevents
restoration of the entire pair. Unsupported connector configurations throw
`UnsupportedError`; invalid arguments throw `ArgumentError`; invalid lifecycle
operations throw `StateError`. SDK unsupported and invalid-model/argument failures
map to `UnsupportedError` and `ArgumentError`. Load-time `LlamaModelException` is
preserved because the SDK cannot distinguish corrupt weights from insufficient
memory. Other SDK failures map to `StateError`; wrappers retain the cause and stack.

## Consumer setup

Declare `ModelFileType.gguf` and register `LlamaEngineProvider`. Put this selection
in the **application/workspace root** pubspec; dependency settings do not propagate:

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

Keep this explicit selection as defence in depth. llamadart 0.15.1 automatically
omits its LiteRT-LM when this connector or `flutter_edge_ai_litertlm` is present;
explicitly selecting both LiteRT-LM owners fails the native build. Core itself includes no inference
runtime. With llamadart 0.15.1, Vulkan is included by default on supported Android,
Linux and Windows targets. Android auto selection uses CPU; Linux/Windows use
Vulkan where available. The demo explicitly selects CPU-only bundles on those
platforms; apps choose backend packaging in their own hook settings.

Apple applications add `llamadart_llama_cpp_flutter: 0.15.0` directly and enable
Flutter SwiftPM. Use iOS 16.4+ and macOS 14+. iOS applications enable the
extended-virtual-addressing and increased-memory-limit entitlements; the example
includes both. Do not apply those kernel entitlements on macOS. From
`flutter_edge_ai_litertlm` 1.19.0 LiteRT-LM keeps SwiftPM on too (its macOS
companions come from its own Swift package): an app with this connector, its
companion and `flutter_edge_ai_litertlm` builds and loads both native libraries
(macOS, 2026-10-24). Running both engines' models in one app is not qualified.
Windows needs the matching Visual C++ runtime. Android's example uses
API 28+ and includes arm64-v8a / x86_64 only; 32-bit armeabi-v7a is unsupported.
The emulator lane runs x86_64. A maintainer-run Galaxy S24 ARM64 CPU smoke passed
on the earlier 0.12.2/0.0.23 pair (see the dated PR record). This is not a recurring
CI lane or qualification of the new SDK pair on phones.
Oldest-device compatibility still requires device testing.

The Apple metadata fix in [native #110](https://github.com/leehack/llamadart-native/issues/110)
is included in companion 0.15.0 (native v0.7.0-1). App Store submission remains
unvalidated. Apple workspace setup is covered below.

Windows x64's first CPU-only build still downloads the full approximately 737 MB
archive, including CUDA DLLs (about 675 MB for cuBLASLt). The SDK download has a
ten-minute total timeout and no resume; allow bandwidth/time for a fresh cache.
Splitting that download belongs to [llamadart #812](https://github.com/leehack/llamadart/issues/812).

## Apple workspaces

With llamadart 0.15.1, the hook discovers the Flutter app member and validates its
Apple companion. The old workspace-root discovery problem is fixed; the hook
uses the SwiftPM runtime rather than embedding another llama.cpp framework.

1. Add `llamadart_llama_cpp_flutter: 0.15.0` directly to the app member's
   `dependencies`, alongside this connector.
2. Set `llamadart_native_runtimes: [llama_cpp]` under `hooks.user_defines.llamadart`
   in the workspace root. Enable Flutter SwiftPM and keep the deployment targets
   and iOS entitlements described above.
3. Run `flutter pub get` from the root, then build or run from the app member.

The hook output is shared across the workspace. App members using llamadart
must declare the same Apple companions. Different companion choices, or a macOS workspace mixing
Flutter apps and Dart entry points that use llamadart, trigger a warning and
retain hook-bundled assets. Such mixed setups remain unqualified here; make the
configuration consistent or split the workspaces.

Qualification uses a workspace containing core, this connector and one app
member, with root hook settings and a companion declared only in the app.
The selected SDK/companion pair is **0.15.1 / 0.15.0**. Both companion 0.15.0
and 0.15.1 are published and accept SDK `>=0.15.0 <0.16.0`; this adapter retains
the tested 0.15.0 companion rather than upgrading it incidentally. Source
qualification and hosted consumer qualification remain independent gates.
This does not qualify App Store submission, physical iOS devices, oldest OS
versions or mixed LiteRT-LM/CocoaPods packaging.

## Example model storage

On Android, enter a GGUF download URL. The demo uses core's downloader instead of
`file_selector_android`, whose current implementation buffers a selected file in
the Java heap and is unsuitable for large models. iOS and desktop pickers copy
into app-owned storage. After a replacement loads, the demo deletes only its old
owned copies; external source files are preserved. Leave room for both copies
while importing. Projector storage remains app-owned.

## Qualification

Inference CI runs release builds for Android, iOS, macOS, Linux, Windows and
Web, with CPU chat/lifecycle baselines on macOS, Linux, Windows, the Android
emulator and iOS simulator. These lanes cover selected fixtures; they do not
qualify every device, model or accelerator.

| Platform | Automated baseline | Additional qualification needed |
| --- | --- | --- |
| Android | Release APK and emulator CPU lifecycle | Physical phones, Vulkan, oldest OS, advanced models |
| iOS | Release build and simulator CPU lifecycle | Physical devices, Metal, App Store validation |
| macOS | Packaged CPU lifecycle | Default-thread performance and model-specific GPU/media/LoRA combinations |
| Windows | Release build and packaged CPU lifecycle | Real hardware, Vulkan/CUDA and advanced combinations |
| Linux | Release build, VM and packaged CPU lifecycle | Real hardware, Vulkan/CUDA and advanced combinations |
| Web | Wasm build and real worker/Wasm generation | Hardware WebGPU, advanced model/browser combinations |

CI uses pinned Flutter 3.47.1 for reproducible checks; that is a test SDK, not the
package minimum. The selected inference pair is llamadart 0.15.1 / Apple
companion 0.15.0, with native artifacts v0.7.0-1 and connector-pinned Web assets
v0.1.65. SDK 0.15.1 adds typed native embedding overflow reporting; its native
inference artifacts are unchanged from 0.15.0. The SDK changelog also includes
Web alignment context; the connector's Web bridge stays at v0.1.65. The
inference baselines above cover the selected fixtures. Validate each
SDK upgrade with the selected companion; its patch version may differ. Web
assets are checksum-verified. llamadart verifies llama.cpp archive SHA-256
digests before extraction
([#1039](https://github.com/leehack/llamadart/pull/1039)); SwiftPM verifies its
companion archives. Existing extracted native caches and explicit local runtime
paths retain the SDK's documented trust policy.

Web `cacheApi` and `none` installs buffer one byte array: use models below about
2 GB, subject to lower device/browser memory limits. Streaming OPFS handles
remain unsupported; select a supported storage mode before downloading.
Memory64 runtime wiring does not lift this installation ceiling. The example
uses a hardware-sized thread pool capped at four; CPU CI profiles are separate.
Required smoke lanes verify machine-reported completion of the model test; skipped
or absent model execution fails. Optional capability fixtures have their own
[explicit runner](development.md), and are not qualified merely because contracts pass.

### Embedding qualification by platform

The following results use the pinned EmbeddingGemma 2 Q8_0 fixture. Inference
qualification does not qualify embeddings or other EG2 quantizations. Source
checks and standalone hosted-consumer checks remain separate gates.

| Platform | Embedding evidence | Remaining scope |
| --- | --- | --- |
| macOS | CPU and Metal measured; packaged lifecycle and CPU/Metal cosine 0.99994 | Other devices, models and quantizations |
| Linux | Packaged CPU embeddings measured | GPU and other hardware |
| Windows | Packaged CPU embeddings measured | GPU and other hardware |
| Android | Maintainer diagnostic on Pixel 8a CPU and explicit Vulkan GPU; see below. Packaged CPU embeddings on the arm64 emulator (API 37, 2026-10-22): min cos 0.99887 to Sentence Transformers fp32 (macOS CPU: 0.99974), automatic placement on the CPU without the warning, explicit GPU refused; CI runs the same gates on the x86_64 emulator | CPU qualification on physical devices; explicit GPU embeddings are refused |
| iOS | Unqualified; simulator GPU embeddings are refused | Physical-device CPU/Metal and simulator CPU embedding execution |
| Web | Unavailable | No GGUF embedding implementation |

Sasha Denisov [reported on 2026-10-21](https://github.com/DenisovAV/flutter_edge_ai/pull/691#pullrequestreview-5597154060)
that macOS CPU and Metal passed the embedding runner. On the core EG2 golden
set (five queries and five documents with core task prefixes), minimum cosine
against Sentence Transformers fp32 `google/embeddinggemma-2` was **0.99974**
on CPU and **0.99990** on Metal. Minimum cosine against the LiteRT EG2 vectors
was **0.977**; use separate GGUF and LiteRT RAG profile IDs.

The same maintainer report measured these diagnostic timings on a **Pixel 8a,
Tensor G3, Mali-G715, Android 14**, with Vulkan added to the example's Android
backends:

| Input words | CPU ms | Explicit GPU ms | CPU/GPU cosine |
| --- | --- | --- | --- |
| 1 | 49 | 2253 | 0.99944 |
| 8 | 57 | 2094 | 0.99926 |
| 38 | 140 | 1768 | 0.99950 |
| 112 | 348 | 4991 | 0.99946 |
| 297 | 1127 | 6050 | 0.99948 |
| 593 | 2835 | 11858 | 0.99949 |

A second CPU load gave cosine **1.000000**. The GPU was approximately **4–46×**
slower across these inputs. These are attributed maintainer diagnostics, not
full Android embedding qualification or release-app performance claims. The
report does not establish the warm-up state. Correct normalized vectors on
this phone do not qualify other GPUs: the ggml-vulkan small-matmul-tile defect
can produce incorrect unit-norm embeddings on affected devices
([llama.cpp #28637](https://github.com/ggml-org/llama.cpp/issues/28637)).
The adapter therefore refuses explicit GPU embeddings on Android and iOS
simulators before loading. With `backendFallback: true`, an explicit GPU
request can load CPU instead; with `false`, the request fails. The diagnostic
GPU timings above describe the measured unguarded path.
See the [embedding guide](embeddings.md) for the supported model profile and
reproducible checks.

## Core 2.5.0 model ownership

GGUF inference continues through `FlutterEdgeAi.getActiveModel()`. This provider
does not opt into `MultiModelEngine`, so `FlutterEdgeAi.openModel()` refuses it
before loading. Supporting several caller-owned models needs separate lifecycle
qualification. The new core API does not change the active-model or embedding
cache contracts qualified here.
