# flutter_edge_ai_mediapipe

> **Renamed from [`flutter_gemma_mediapipe`](https://pub.dev/packages/flutter_gemma_mediapipe).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_mediapipe/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

MediaPipe (`.task`) on-device inference engine for [`flutter_edge_ai`](https://pub.dev/packages/flutter_edge_ai). Opt-in package — add it only if you run MediaPipe `.task` models. Android, iOS, and Web.

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

`MediaPipeEngine` handles `ModelFileType.task` / `ModelFileType.binary` (`.bin`) models; pass it alongside other engines (e.g. `LiteRtLmEngine` from `flutter_edge_ai_litertlm`) if your app uses both formats.

## Web setup

On Web, the MediaPipe runtime is loaded from a CDN. Add this to your app's `web/index.html` (inside a `<script type="module">` before your Flutter bootstrap), exposing the symbols on `window`:

```html
<script type="module">
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
```

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
| Android  | ✅ `com.google.mediapipe:tasks-genai` (Gradle) |
| iOS      | ✅ `MediaPipeTasksGenAI` (CocoaPods) — **requires iOS 16.0+** |
| Web      | ✅ `@mediapipe/tasks-genai` (CDN, see above) |
| Desktop  | ❌ (MediaPipe `.task` not supported on desktop — use `flutter_edge_ai_litertlm`) |
