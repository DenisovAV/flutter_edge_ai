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

`MediaPipeEngine` handles `ModelFileType.task` / `.bin` models. Pass it
alongside other engines (e.g. `LiteRtLmEngine` from `flutter_edge_ai_litertlm`) if
your app uses both formats — the registry routes each model to the right one.

> **iOS:** this package requires **iOS 16.0+** (MediaPipe GenAI's floor — it is
> the only flutter_edge_ai package that needs it). Set `platform :ios, '16.0'` in
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
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
```

The pinned version is **`@mediapipe/tasks-genai@0.10.29`**. Web runs **GPU-only**:
the web engine ignores `preferredBackend` and always runs on the browser's GPU
(WebGPU). The model storage helpers (`cache_api.js`, `opfs_helper.js`) are
needed as well — see [Installation → Web](/docs/installation#web).
**Vision** works on Web with Gemma 4's `.task` web build; thinking mode
(`extraContext`) is not available through MediaPipe on Web.

## Backends

| `PreferredBackend` | Android | iOS | Web |
|--------------------|---------|-----|-----|
| `cpu` | ✅ | ✅ | ignored — runs on GPU |
| `gpu` | ✅ | ✅ | ✅ (always) |

Pass the backend when you open the model:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  preferredBackend: PreferredBackend.gpu,
);
```

## See also

- [Models](/docs/models) — supported models, formats, and download sources
- [LiteRT-LM](/docs/litertlm) — the `.litertlm` engine (mobile **and** desktop)
- [Packages](/docs/packages) — the full opt-in package list and their APIs

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-mediapipe`](/docs/package-skills), the skill that teaches it `.task` and `.bin` models on Android, iOS and web.
