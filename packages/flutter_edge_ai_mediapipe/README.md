# flutter_edge_ai_mediapipe

> **Renamed from [`flutter_gemma_mediapipe`](https://pub.dev/packages/flutter_gemma_mediapipe).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_mediapipe/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

MediaPipe (`.task`) on-device inference engine for [`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai). Opt-in package — add it only if you run MediaPipe `.task` models. Android, iOS, and Web.

> **Google moved MediaPipe LLM Inference to maintenance-only.** New features and optimizations focus on LiteRT-LM, so a new app should use `.litertlm` models with [`flutter_edge_ai_litertlm`](https://pub.dev/packages/flutter_edge_ai_litertlm). On iOS, do not load a `.task` model on the GPU: Gemma 3 1B reached the app's memory limit while loading and iOS terminated the app ([details](https://flutteredge.ai/docs/mediapipe#backends)).

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-mediapipe`, covers `.task` and `.bin` models on Android, iOS and web.

## Usage

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';

await FlutterEdgeAi.initialize(
  inferenceEngines: [MediaPipeEngine()],
);
```

`MediaPipeEngine` handles `ModelFileType.task` / `ModelFileType.binary` (`.bin`, `.tflite`) models; pass it alongside other engines (e.g. `LiteRtLmEngine` from `flutter_edge_ai_litertlm`) if your app uses both formats.

`maxTokens` is the whole context (input plus output), and a small value is not raised as it is on `.litertlm`. `maxOutputTokens` is ignored (only a debug log says so); stop early with `session.stopGeneration()`.

On Android and iOS, pass `supportImage: true` to `createChat` as well as to `getActiveModel`, or the image is dropped. The Gemma 3n `.task` files carry no audio encoder; use a `.litertlm` model for audio.

## Sampling

A `.task` file ships no sampler, so an unset `temperature`, `topK` or `topP` comes from the model family's defaults (`SamplingParams.forModelType`), with an unset `topK` capped at 40, MediaPipe's own default; an unset `randomSeed` is 1. `topK: 1` or `temperature: 0` decodes greedily, as Phi and Hammer do by default; before 1.2.0 every family did. On Android and iOS each session starts from its seed, so vary `randomSeed` for a different answer to the same prompt. On web the model keeps its first session, so the sampling of a later `createSession` is not applied; web also has no top-p, and a `topP` you pass is ignored with a one-time warning.

## Web setup

On Web, the MediaPipe runtime is loaded from a CDN. Add this to your app's `web/index.html` (inside a `<script type="module">` before your Flutter bootstrap), exposing the symbols on `window`:

```html
<script type="module">
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
```

Load the model's `-web.task` build (e.g. `gemma3-1b-it-int4-web.task`); mobile `.task` files generally do not run on web. Also copy `cache_api.js` and `opfs_helper.js` from the `flutter_edge_ai` package's `web/` directory into your app's `web/` and load them with `<script src="cache_api.js"></script>` and `<script src="opfs_helper.js"></script>` — see [Installation → Web](https://flutteredge.ai/docs/installation#web). Web runs on the GPU only.

(Android needs no extra setup — the MediaPipe Gradle deps are bundled by this package.)

## iOS setup

**iOS needs a 16.0 minimum.** MediaPipe GenAI requires it, and this is the only
flutter_edge_ai package that does — core, `flutter_edge_ai_litertlm`, built-in AI and
embeddings build from 15.0 (#441).

This package ships no `Package.swift`, so even an app on Swift Package Manager gets a
`Podfile` for it. Set the floor in BOTH places: `platform :ios, '16.0'` in the `Podfile`,
and **iOS Deployment Target** on the Runner target in Xcode. Below 16, `pod install`
reports that specs satisfying the `flutter_edge_ai_mediapipe` dependency "required a higher
minimum deployment target".

MediaPipe ships static xcframeworks, so the `Podfile` also needs
`use_frameworks! :linkage => :static` — with the Flutter template's bare
`use_frameworks!`, `pod install` fails on "transitive dependencies that include
statically linked binaries".

## Platforms

| Platform | Support |
|----------|---------|
| Android  | ✅ `com.google.mediapipe:tasks-genai` 0.10.33 (Gradle) |
| iOS      | ✅ `MediaPipeTasksGenAI` 0.10.33 (CocoaPods) — **requires iOS 16.0+**; run `.task` models on `PreferredBackend.cpu` |
| Web      | ✅ `@mediapipe/tasks-genai` 0.10.29 (CDN, see above) — GPU only, `-web.task` models |
| Desktop  | ❌ (MediaPipe `.task` not supported on desktop — use `flutter_edge_ai_litertlm`) |
