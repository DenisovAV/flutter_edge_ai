# litertlm_dart

[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) from Dart, without
Flutter: `dart:ffi` over LiteRT-LM's C API, with the native libraries fetched
and bundled by a build hook. It is the runtime under
[`flutter_edge_ai_litertlm`](https://pub.dev/packages/flutter_edge_ai_litertlm)
and [`flutter_edge_ai_speech`](https://pub.dev/packages/flutter_edge_ai_speech);
a Flutter app uses those, through
[`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai).

## What it holds

- **The native build.** `hook/build.dart` downloads our patched LiteRT-LM build
  (`native-v*` releases of this repository, SHA256-verified) for Android
  arm64, iOS, macOS arm64, Linux x64/arm64 and Windows x64, and registers it
  as code assets. Patches over upstream include rewinding a stopped turn,
  NPU fixes and the thinking-budget fix (`native/litert_lm/patch_c_api.sh`).
- **NPU stacks.** Qualcomm (Android, Linux arm64), Google Tensor and MediaTek
  (Android), Intel (Windows x64), with the vendor runtimes fetched on request.
- **The runtime.** The `.litertlm` bundle reader and load plan, the LLM client
  with native and replayed sessions, sampler resolution from the bundle,
  response constraints, the thinking budget, the EmbeddingGemma 2 embedder
  and option scoring.

## Versions

The version is the upstream LiteRT-LM version this package is built from,
plus a build number for our native rebuilds of it: `0.19.1+1` is LiteRT-LM
0.19.1 on `native-v0.19.1-b`. Within one upstream version the Dart API stays
compatible; a breaking change comes with an upstream version change. Depend on
it as `'>=0.19.1+1 <0.19.2'`.

## Libraries

- `package:litertlm_dart/litertlm_dart.dart` — the runtime (native only).
- `package:litertlm_dart/common.dart` — the types, limits and errors, with no
  `dart:io` or `dart:ffi`, so code that names them compiles for the web.
- `package:litertlm_dart/bindings.dart`, `litert_bindings.dart` — the raw
  ffigen bindings to LiteRT-LM's and LiteRT's C APIs.

## Build options

Set under `hooks: user_defines: litertlm_dart:` in the app's pubspec (the
workspace root's, if the app is a workspace member):

```yaml
hooks:
  user_defines:
    litertlm_dart:
      qualcomm_npu: true       # bundle Qualcomm's QNN runtime (Android, Linux arm64)
      google_tensor_npu: true  # Google Tensor G5/G6
      mediatek_npu: true       # MediaTek Dimensity
```

The key apps set before this package existed, `flutter_edge_ai_litertlm:`, is
still read, with a warning, until the next upstream LiteRT-LM version.

The native libraries are cached per release under
`~/Library/Caches/litertlm_dart/native/` (macOS), `~/.cache/litertlm_dart/native/`
(Linux) or `%LOCALAPPDATA%\litertlm_dart\native\` (Windows).
