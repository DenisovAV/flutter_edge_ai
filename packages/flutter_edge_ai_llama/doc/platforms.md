# Platform support

The connector provides GGUF inference through llamadart on Android, iOS, macOS,
Windows, Linux and Web. It requires Flutter 3.44+, Dart 3.12+ and core 2.3.2+.
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
operations throw `StateError`. llamadart runtime failures retain their runtime exceptions.

## Consumer setup

Declare `ModelFileType.gguf` and register `LlamaEngineProvider`. Put this selection
in the **application/workspace root** pubspec; dependency settings do not propagate:

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
```

Keep this explicit selection as defence in depth. llamadart 0.12.0 automatically
omits its LiteRT-LM when this connector or `flutter_edge_ai_litertlm` is present;
explicitly selecting both LiteRT-LM owners fails the native build. Core itself includes no inference
runtime. With llamadart 0.12.0, Vulkan is included by default on supported Android,
Linux and Windows targets. Android auto selection uses CPU; Linux/Windows use
Vulkan where available. The demo explicitly selects CPU-only bundles on those
platforms; apps choose backend packaging in their own hook settings.

Apple applications add `llamadart_llama_cpp_flutter: 0.0.22` directly and enable
Flutter SwiftPM. Use iOS 16.4+ and macOS 14+. iOS applications enable the
extended-virtual-addressing and increased-memory-limit entitlements; the example
includes both. Do not apply those kernel entitlements on macOS. The published
LiteRT-LM macOS CocoaPods setup disables SwiftPM, so combining that setup with this
SwiftPM companion is not qualified; use separate apps until a shared recipe is
validated. Windows needs the matching Visual C++ runtime. Android's example uses
API 24+ and includes arm64-v8a / x86_64 only; 32-bit armeabi-v7a is unsupported.
The current emulator lane runs x86_64; an ARM64 phone run remains a publication gate.
Oldest-device compatibility still requires device testing.

App Store submission remains unvalidated pending [native framework metadata
#110](https://github.com/leehack/llamadart-native/issues/110). Apple workspace
member apps with root hook settings are unqualified: fallback frameworks can be
embedded alongside the companion and carry inconsistent deployment metadata.
Use a standalone Apple app until that owning-runtime path is validated.

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
package minimum. Runtime pins are llamadart 0.12.0, native artifacts v0.6.0-2,
Apple companion 0.0.22 and connector-pinned Web assets v0.1.59. Upgrade the SDK
constraint and companion together. Web assets are checksum-verified. The SDK's
llama.cpp native archive downloads do **not** yet verify pinned SHA-256 hashes;
that work remains in [llamadart #1015](https://github.com/leehack/llamadart/issues/1015).

Web `cacheApi` and `none` installs buffer one byte array: use models below about
2 GB, subject to lower device/browser memory limits. Streaming OPFS handles
remain unsupported; select a supported storage mode before downloading.
Memory64 runtime wiring does not lift this installation ceiling. The example
uses a hardware-sized thread pool capped at four; CPU CI profiles are separate.
Required smoke lanes verify machine-reported completion of the model test; skipped
or absent model execution fails. Optional capability fixtures have their own
[explicit runner](development.md), and are not qualified merely because contracts pass.
