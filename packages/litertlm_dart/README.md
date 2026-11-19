# litertlm_dart

[LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) in pure Dart, with
no Flutter dependency: `dart:ffi` over LiteRT-LM's C API, with the native
libraries fetched and bundled by a build hook. Today it runs inside Flutter
apps (see [Where it runs today](#where-it-runs-today)). It is the runtime under
[`flutter_edge_ai_litertlm`](https://pub.dev/packages/flutter_edge_ai_litertlm)
and [`flutter_edge_ai_speech`](https://pub.dev/packages/flutter_edge_ai_speech);
a Flutter app uses those, through
[`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai).

## Use

The API follows LiteRT-LM's Kotlin and Swift APIs: an `Engine` loads a
`.litertlm` model on a backend, a `Conversation` streams replies, an
`EmbeddingEngine` embeds with EmbeddingGemma 2.

```dart
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';

final engine = await Engine.create(
  EngineConfig(
    modelPath: 'gemma-4-E2B-it.litertlm',
    backend: const Backend.gpu(),
    maxNumTokens: 4096, // the context window, not the reply length
  ),
);
final conversation = await engine.createConversation(
  ConversationConfig(
    systemInstruction: 'Answer in one sentence.',
    maxOutputTokens: 256,
  ),
);
await for (final piece in conversation.sendMessageStream(
  Message.user('Why is the sky blue?'),
)) {
  stdout.write(piece.text);
}
await conversation.close();
await engine.close();
```

`Message`, `Tool`, `ResponseFormat` and `ActivationDataType` carry the names
of LiteRT-LM's Kotlin and Swift APIs, and `flutter_edge_ai` has types of the
same names. In code that imports both, import this package with a prefix:
`import 'package:litertlm_dart/litertlm_dart.dart' as lm;`.

- **Messages** are `Message`s of `Content` parts in any order:
  `Content.text`, `.imageBytes`/`.imageFile`, `.audioBytes`/`.audioFile`,
  `.toolResponse`. A reply streams as `Message`s: text parts, a thought in
  `channels['thought']`, calls in `toolCalls`.
- **Tools** are declared with `Tool(name:, description:, parameters:)`; the
  model's calls arrive as `ToolCall`s and you answer with
  `Message.tool([Content.toolResponse(name, result)])`. There is no automatic
  tool loop: running app code is the caller's policy.
- **Decoding**: `SamplerConfig` (unset: the model file's own sampler),
  `ThinkingConfig` with a token budget, `ResponseFormat.json`/`.regex` (on the
  hosts and backends where constrained decoding was qualified; elsewhere
  `createConversation` throws `ConstraintUnsupportedException`), and per
  message `RepetitionPenaltyConfig`, `NoRepeatNgramConfig`, `suppressTokens`,
  `extraContext`. `SpeculativeDecodingMode` on the engine and per conversation.
- **Stopping**: `Conversation.cancel()` stops and keeps what was generated;
  cancelling the subscription stops and drops the rest. A reply that ends
  completes its stream; a failed turn ends it with a `LiteRtLmException`:
  `ContextFullException`, `ConversationClosedException`,
  `TurnFailedException`, ….
- **Embeddings** (`EmbeddingEngine`): a per-SoC bundle runs on its NPU only;
  the GPU is taken where it was measured and refused elsewhere — nothing moves
  to another backend on its own.
- **Backends**: `Backend.cpu(threadCount:)`, `.gpu()`, `.npu()`. The NPU
  vendor (Qualcomm, Google Tensor, MediaTek, Intel) is read from the bundle;
  `Backend.npu(dispatchDir:)` names a directory holding that vendor's
  dispatch libraries, and only that vendor's (null: beside the executable,
  where the build puts them on Linux and Windows; on Android see below);
  vision and audio encoders load only when asked (`EngineConfig.visionBackend`,
  `audioBackend`), `BundleInfo.declaredVisionBackend` is where the file wants
  them.

What it adds to the official APIs: several conversations per engine, with a
stopped, refused or failed turn recovered before the next (rewound where the
backend can, our patch); the bundle read without loading it
(`readBundleInfo`); `Engine.tokenize`/`detokenize` and `scoreTargets` (exact
log-probabilities of continuations); EmbeddingGemma 2 with images, audio and
both in one vector, on the CPU, the GPU where measured and per-SoC NPU bundles.
Not yet: LoRA, `tool_choice` and the other LiteRT-LM 0.20 additions.

## What it holds

- **The native build.** `hook/build.dart` downloads our patched LiteRT-LM build
  (`native-v*` releases of this repository, SHA256-verified) for Android
  arm64, iOS, macOS arm64, Linux x64/arm64 and Windows x64, and registers it
  as code assets. Patches over upstream include rewinding a stopped turn,
  NPU fixes and the thinking-budget fix (`native/litert_lm/patch_c_api.sh`).
- **NPU stacks.** Qualcomm (Android, Linux arm64), Google Tensor and MediaTek
  (Android), Intel (Windows x64), with the vendor runtimes fetched on request.

## Versions

The version is the upstream LiteRT-LM version this package is built from,
plus a build number for our native rebuilds of it: `0.19.1+1` is LiteRT-LM
0.19.1 on `native-v0.19.1-c`. Within one upstream version the Dart API stays
compatible; a breaking change of the Dart API comes only with an upstream
version change, so the API of one upstream version is fixed once published.

`dart pub add litertlm_dart` writes `^0.19.1+1`. For a 0.x version a caret
range stays below the next minor, so it also takes 0.19.2 and later 0.19.x
releases, which follow newer LiteRT-LM releases and may change the Dart API.
To stay on one LiteRT-LM release, bound it at the next upstream patch:

```yaml
dependencies:
  litertlm_dart: '>=0.19.1+1 <0.19.2'
```

## Where it runs today

The runtime and the hook are what `flutter_edge_ai_litertlm` runs on Android,
iOS, macOS, Linux and Windows. On its own, without that package, it is not yet
a finished story:

- **Android:** `flutter_edge_ai`'s manifest declares the vendor libraries the
  GPU and the NPU load (`libOpenCL.so`, `libvndksupport.so`, `libcdsprpc.so`,
  the Google Tensor and NeuroPilot libraries) as `uses-native-library`; an app
  without it declares them itself, or the GPU and the NPU do not load from
  Android 12. For `Backend.npu`, the NPU dispatch is inside the APK: an app's
  `nativeLibraryDir` holds it only with `extractNativeLibs="true"`, and then
  holds every vendor the app ships, of which LiteRT takes the first.
  `flutter_edge_ai_litertlm` copies one vendor's libraries into a directory of
  their own through `flutter_edge_ai`'s platform channel; an app without them
  has to do the same and pass that directory as `dispatchDir:`.
- **macOS:** the hook leaves two companion libraries (the constraint provider
  and the Metal accelerator) to the app's build — `flutter_edge_ai_litertlm`'s
  Swift package or its Podfile step embeds them. A macOS app that depends on
  `litertlm_dart` alone, and a plain Dart program on macOS, cannot load the
  engine yet.
- **Library lookup** follows the layout of a Flutter app bundle; `dart run` and
  `dart build cli` layouts are not looked up yet.
- **With `flutter_edge_ai_litertlm` 1.20.x or older** in the same app, both
  build hooks bundle `libLiteRtLm`, each under its own package's asset id,
  and the build does not catch it: on Android one copy overwrites the other,
  on Apple a second framework is added. Which LiteRT-LM build the app runs is
  then not defined. Use `flutter_edge_ai_litertlm` 1.21.0 or newer, which
  builds on this package.

A plain Dart program and the macOS companions are planned with a
command-line example.

## Libraries

- `package:litertlm_dart/litertlm_dart.dart` — the API above (native only).
- `package:litertlm_dart/bindings.dart`, `litert_bindings.dart` — the raw
  ffigen bindings to LiteRT-LM's and LiteRT's C APIs, outside the
  compatibility promise.
- `package:litertlm_dart/internal.dart`, `internal_io.dart` — what
  `flutter_edge_ai_litertlm` and its tests build on; no compatibility promise.

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

On the MediaTek NPU every turn runs in a fresh native conversation that
replays the history: there a conversation answers its second message empty
(MT6989, LiteRT-LM #4256).

The key apps set before this package existed, `flutter_edge_ai_litertlm:`, is
still read, with a warning, until the next upstream LiteRT-LM version.

The native libraries are cached per release under
`~/Library/Caches/litertlm_dart/native/` (macOS), `~/.cache/litertlm_dart/native/`
(Linux) or `%LOCALAPPDATA%\litertlm_dart\native\` (Windows).
