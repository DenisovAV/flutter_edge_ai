---
title: MediaPipe
description: Run .task / .bin models on Android, iOS and Web through Google's MediaPipe (tasks-genai) engine — chat templates handled internally for .task, GPU-only on Web.
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

flutter_edge_ai's engines are **pluggable**: you register them in
`FlutterEdgeAi.initialize(...)`, and the registry picks one per model by its
declared `ModelFileType`. `flutter_edge_ai_mediapipe` is the engine for Google's
**MediaPipe** runtime (`tasks-genai`) — it runs `.task` bundles (and `.bin`).
A `.task` archive packages the model's `.tflite` weights, tokenizer, and
metadata together, and **MediaPipe applies each model's chat template
internally**, so you feed plain messages and it handles the formatting. A `.bin`
model carries no template: flutter_edge_ai adds the turn markers itself from the
`ModelType` you install it with — as it does for FunctionGemma `.task`, whose
bundle has none either.

> **MediaPipe LLM Inference is in maintenance mode.** Google moved the LLM
> Inference API (Android, iOS and Web) to maintenance-only: new features and
> optimizations focus on [LiteRT-LM](/docs/litertlm), and the iOS SDK marks
> `LlmInference`, `Session` and their options deprecated. For a new app, use
> `.litertlm` models with `flutter_edge_ai_litertlm`; keep this engine for
> `.task` and `.bin` models you already ship, and on web for models published
> only as `-web.task`.

## Platforms

| Platform | Support | Runtime |
|----------|---------|---------|
| Android | ✅ | `com.google.mediapipe:tasks-genai` (Gradle) |
| iOS | ✅ | `MediaPipeTasksGenAI` (CocoaPods) — **requires iOS 16.0+** |
| Web | ✅ | `@mediapipe/tasks-genai` (CDN) |
| Desktop (macOS/Windows/Linux) | ❌ | no MediaPipe engine — use [LiteRT-LM](/docs/litertlm) or ONNX |

> **Mobile + Web only.** There is no MediaPipe engine on desktop; for
> macOS/Windows/Linux run the `.litertlm` format via
> [LiteRT-LM](/docs/litertlm) instead.

## Setup

Add the package and register `MediaPipeEngine()` at startup, alongside any other
engines your app uses:

```
dependencies:
  flutter_edge_ai: latest_version
  flutter_edge_ai_mediapipe: latest_version   # MediaPipe .task engine
```

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: [MediaPipeEngine()],
);
```

`MediaPipeEngine` handles `ModelFileType.task` and `ModelFileType.binary` (`.bin`, `.tflite`) models. Pass it
alongside other engines (e.g. `LiteRtLmEngine` from `flutter_edge_ai_litertlm`) if
your app uses both formats — the registry routes each model to the right one.

> **iOS:** this package requires **iOS 16.0+** (MediaPipe GenAI's floor; core
> builds from iOS 15, and [`flutter_edge_ai_llama`](/docs/llama) needs iOS
> 16.4+). Set `platform :ios, '16.0'` in
> the `Podfile` **and** the Runner's iOS Deployment Target in Xcode, and use
> `use_frameworks! :linkage => :static` (MediaPipe ships static xcframeworks).
> Android needs no extra setup — the MediaPipe Gradle deps are bundled.

## Install a `.task` model

`installModel` defaults `fileType` to `ModelFileType.task`, so a `.task` model
needs **no explicit file-type declaration**:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
).fromNetwork('https://.../gemma3-1b-it.task').install();

final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final session = await model.createSession();
await session.addQueryChunk(const Message(text: 'Hello!', isUser: true));
final response = await session.getResponse();
```

Models can also come from an asset, a bundled file, or a local path — see
[Models](/docs/models) for every source and the model catalog.

## Web setup

On Web the MediaPipe runtime is loaded from a CDN. Add this to your app's
`web/index.html` inside a `<script type="module">` (before the Flutter
bootstrap), exposing the symbols on `window`:

```
<script type="module">
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.30';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
```

The pinned version is **`@mediapipe/tasks-genai@0.10.30`**. Web runs **GPU-only**:
the web engine ignores `preferredBackend` and always runs on the browser's GPU
(WebGPU). The model storage helpers (`cache_api.js`, `opfs_helper.js`) are
needed as well — see [Installation → Web](/docs/installation#web).
**Vision** works on Web with Gemma 4's `.task` web build; thinking mode
(`extraContext`) is not available through MediaPipe on Web.

MediaPipe on Web keeps nothing between calls, so the session sends the whole
conversation, the model's replies included, with every turn. Each answer
re-reads the history, so its time grows with the chat, and `maxNumImages`
counts every image of the conversation. A turn that would exceed it fails with
an error naming `maxNumImages`; nothing is dropped. Each `createSession` or
`createChat` starts a new conversation.

## Backends

| `PreferredBackend` | Android | iOS | Web |
|--------------------|---------|-----|-----|
| `cpu` | ✅ | ✅ | ignored — runs on GPU |
| `gpu` | ✅ | ⚠️ see below | ✅ (always) |

> **iOS GPU: use `.litertlm`.** Google lists Gemma 3 1B and Gemma 3n for
> Android and Web only. On an iPhone 17 Pro (iOS 26.5.2, MediaPipe 0.10.33 and
> 0.10.35), `gemma3-1b-it-int4.task` on `PreferredBackend.gpu` reached that
> iPhone's 6655 MB per-process memory limit while loading (memory entitlements
> present), and iOS terminated the app without a crash report;
> `gemma-3n-E2B-it-int4.task` failed to initialize the GPU delegate. The same
> Gemma 3 1B `.task` runs on CPU, and the same model as `.litertlm` runs on the
> iPhone GPU through LiteRT-LM in under 1 GB (measured with
> `gemma3-1b-it-int4.litertlm`, byte-identical to the registry's
> [`Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm`](/docs/registry#gemma-3-1b-it)).

Pass the backend when you open the model:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  preferredBackend: PreferredBackend.gpu, // on iOS: PreferredBackend.cpu
);
```

## See also

- [Models](/docs/models) — supported models, formats, and download sources
- [LiteRT-LM](/docs/litertlm) — the `.litertlm` engine (mobile **and** desktop)
- [Packages](/docs/packages) — the full opt-in package list and their APIs

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-mediapipe`](/docs/package-skills), the skill that teaches it `.task` and `.bin` models on Android, iOS and web.
