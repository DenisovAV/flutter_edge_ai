# Platform support

The connector provides GGUF inference through llamadart on Android, iOS, macOS,
Windows, Linux and Web. It requires Flutter 3.44+, Dart 3.12+ and core 2.4.0+.
A passing build does not qualify every device, model or accelerator.

| Feature | Native | Web |
| --- | --- | --- |
| GGUF text, independent chats and cancellation | Supported; inference shares one serialized runtime | Supported through the bridge worker |
| CPU | Supported | Supported through Wasm |
| GPU | Depends on the selected backend and device | Depends on browser WebGPU and runtime capabilities |
| Tools and thinking | Compatible model/template required | Compatible model/template/grammar required |
| Images and audio | Compatible app-owned projector required | Compatible projector and bridge capabilities required |
| LoRA | Installed adapter loads with the model; temporary session overrides are serialized | This connector does not wire Web adapters; it rejects installed or session adapters |
| GGUF embeddings | Deferred to a separate package contribution | Deferred |
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

Keep this explicit selection as defence in depth. llamadart 0.13.0 automatically
omits its LiteRT-LM when this connector or `flutter_edge_ai_litertlm` is present;
explicitly selecting both LiteRT-LM owners fails the native build. Core itself includes no inference
runtime. With llamadart 0.13.0, Vulkan is included by default on supported Android,
Linux and Windows targets. Android auto selection uses CPU; Linux/Windows use
Vulkan where available. The demo explicitly selects CPU-only bundles on those
platforms; apps choose backend packaging in their own hook settings.

Apple applications add `llamadart_llama_cpp_flutter: 0.13.0` directly and enable
Flutter SwiftPM. Use iOS 16.4+ and macOS 14+. iOS applications enable the
extended-virtual-addressing and increased-memory-limit entitlements; the example
includes both. Do not apply those kernel entitlements on macOS. The published
LiteRT-LM macOS CocoaPods setup disables SwiftPM, so combining that setup with this
SwiftPM companion is not qualified; use separate apps until a shared recipe is
validated. Windows needs the matching Visual C++ runtime. Android's example uses
API 28+ and includes arm64-v8a / x86_64 only; 32-bit armeabi-v7a is unsupported.
The emulator lane runs x86_64. A maintainer-run Galaxy S24 ARM64 CPU smoke passed
on the earlier 0.12.2/0.0.23 pair (see the dated PR record). This is not a recurring
CI lane or qualification of the new SDK pair on phones.
Oldest-device compatibility still requires device testing.

The Apple metadata fix in [native #110](https://github.com/leehack/llamadart-native/issues/110)
is included in companion 0.13.0 (native v0.6.0-3). App Store submission remains
unvalidated. Apple workspace-member apps are also unqualified: the companion is
always missed when it is declared only in a member and the hook runs from the
root, so fallback frameworks can be embedded alongside it. Use a standalone
Apple app until that runtime packaging path is validated.

Windows x64's first CPU-only build still downloads the full approximately 737 MB
archive, including CUDA DLLs (about 675 MB for cuBLASLt). The SDK download has a
ten-minute total timeout and no resume; allow bandwidth/time for a fresh cache.
Splitting that download belongs to [llamadart #812](https://github.com/leehack/llamadart/issues/812).

## Example model storage

On Android, enter a GGUF download URL. The demo uses core's downloader instead of
`file_selector_android`, whose current implementation buffers a selected file in
the Java heap and is unsuitable for large models. iOS and desktop pickers copy
into app-owned storage. After a replacement loads, the demo deletes only its old
owned copies; external source files are preserved. Leave room for both copies
while importing. Projector storage remains app-owned.

## Qualification

The required CI baseline covers the builds and runtime lanes below. Passing that
baseline qualifies the tested CPU fixture and lifecycle, not every combination in
the support matrix. Dated devices, models, commands and results are recorded in the
[contribution PR](https://github.com/DenisovAV/flutter_edge_ai/pull/628).

| Platform | Automated baseline | Additional qualification needed |
| --- | --- | --- |
| Android | Release APK and emulator CPU lifecycle | Physical phones, Vulkan, oldest OS, advanced models |
| iOS | Release build and simulator CPU lifecycle | Physical devices, Metal, App Store validation |
| macOS | Packaged CPU lifecycle | Default-thread performance and model-specific GPU/media/LoRA combinations |
| Windows | Release build and packaged CPU lifecycle | Real hardware, Vulkan/CUDA and advanced combinations |
| Linux | Release build, VM and packaged CPU lifecycle | Real hardware, Vulkan/CUDA and advanced combinations |
| Web | Wasm build and real worker/Wasm generation | Hardware WebGPU, advanced model/browser combinations |

CI uses pinned Flutter 3.47.1 for reproducible checks; that is a test SDK, not the
package minimum. Runtime pins are llamadart 0.13.0, native artifacts v0.6.0-3,
Apple companion 0.13.0 and connector-pinned Web assets v0.1.59. Upgrade the SDK
constraint and companion together. Web assets are checksum-verified. llamadart 0.13.0 verifies llama.cpp archive SHA-256 digests before extraction
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
