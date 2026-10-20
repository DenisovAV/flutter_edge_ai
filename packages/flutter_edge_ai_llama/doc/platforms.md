# Platform support

The connector provides GGUF inference through llamadart on Android, iOS, macOS,
Windows, Linux and Web. It requires Flutter 3.44+, Dart 3.12+ and core 2.4.0+.
A passing build does not qualify every device, model or accelerator.

Version 0.0.2 pairs llamadart 0.15.0 with Apple companion
`llamadart_llama_cpp_flutter` 0.15.0 (0.0.1 paired 0.13.1 with 0.13.0).

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

Keep this explicit selection as defence in depth. llamadart 0.15.0 automatically
omits its LiteRT-LM when this connector or `flutter_edge_ai_litertlm` is present;
explicitly selecting both LiteRT-LM owners fails the native build. Core itself includes no inference
runtime. With llamadart 0.15.0, Vulkan is included by default on supported Android,
Linux and Windows targets. Android auto selection uses CPU; Linux/Windows use
Vulkan where available. The demo explicitly selects CPU-only bundles on those
platforms; apps choose backend packaging in their own hook settings.

Apple applications add `llamadart_llama_cpp_flutter: 0.15.0` directly and enable
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
is included in companion 0.15.0 (native v0.7.0-1). App Store submission remains
unvalidated. Apple workspace setup is covered below.

Windows x64's first CPU-only build still downloads the full approximately 737 MB
archive, including CUDA DLLs (about 675 MB for cuBLASLt). The SDK download has a
ten-minute total timeout and no resume; allow bandwidth/time for a fresh cache.
Splitting that download belongs to [llamadart #812](https://github.com/leehack/llamadart/issues/812).

## Apple workspaces

With llamadart 0.15.0, the hook discovers the Flutter app member and validates its
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
The configured SDK/companion pair is **0.15.0 / 0.15.0**. The
[contribution PR](https://github.com/DenisovAV/flutter_edge_ai/pull/628) records
the previous 0.13.1 / 0.13.0 qualification; upgrading the pins does not carry
that qualification forward automatically.
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

The required CI baseline covers the builds and runtime lanes below. The 0.15.0
upgrade passed local contracts and hosted-package validation, Android arm64
emulator/iOS arm64 simulator/macOS CPU lifecycle, macOS Metal generation,
selected native tools/thinking/image/audio fixtures and Web worker/Wasm inference.
Android, iOS (unsigned), macOS and Web release builds passed; the Android APK
passed ABI, native dependency and 16 KB alignment checks. Linux/Windows and the
Flutter 3.44 minimum SDK are separate required CI lanes. These checks
qualify the selected fixtures and lifecycle, not every combination in the support
matrix.

| Platform | Automated baseline | Additional qualification needed |
| --- | --- | --- |
| Android | Release APK and emulator CPU lifecycle | Physical phones, Vulkan, oldest OS, advanced models |
| iOS | Release build and simulator CPU lifecycle | Physical devices, Metal, App Store validation |
| macOS | Packaged CPU lifecycle | Default-thread performance and model-specific GPU/media/LoRA combinations |
| Windows | Release build and packaged CPU lifecycle | Real hardware, Vulkan/CUDA and advanced combinations |
| Linux | Release build, VM and packaged CPU lifecycle | Real hardware, Vulkan/CUDA and advanced combinations |
| Web | Wasm build and real worker/Wasm generation | Hardware WebGPU, advanced model/browser combinations |

CI uses pinned Flutter 3.47.1 for reproducible checks; that is a test SDK, not the
package minimum. Runtime pins are llamadart 0.15.0, native artifacts v0.7.0-1,
Apple companion 0.15.0 and connector-pinned Web assets v0.1.65. Validate SDK
upgrades with the matching companion; its patch version may differ. Web assets are checksum-verified. llamadart 0.15.0 verifies llama.cpp archive SHA-256 digests before extraction
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
