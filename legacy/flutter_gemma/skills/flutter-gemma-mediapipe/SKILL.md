---
name: flutter-gemma-mediapipe
description: Use when running .task or .bin models (MediaPipe GenAI, ModelFileType.task or ModelFileType.binary) with flutter_gemma_mediapipe on Android, iOS or web. Also use when CocoaPods rejects the iOS platform version, images are ignored in a MediaPipe chat, or maxOutputTokens has no effect. MediaPipe has no macOS, Windows or Linux support — use a .litertlm model there (flutter-gemma-inference).
---

# The MediaPipe engine

## Rules

1. Depend on `flutter_gemma` and `flutter_gemma_mediapipe`, and import both. The engine package does not re-export core.
2. Declare `fileType: ModelFileType.task` for `.task` files and `ModelFileType.binary` for `.bin` files.
3. An app that includes this package needs iOS 16.0.
4. There is no desktop support.
5. `maxTokens` is the real context limit — small values are not raised as they are on `.litertlm`. `maxOutputTokens` is ignored; stop generation with `session.stopGeneration()`.
6. On Android and iOS, `createChat` inherits the model's audio support but **not** its image support — pass `supportImage: true` to the chat as well, or the image is dropped.

## Setup

```sh
flutter pub add flutter_gemma flutter_gemma_mediapipe
```

```dart
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';

await FlutterGemma.initialize(inferenceEngines: [MediaPipeEngine()]);

await FlutterGemma.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.task,
).fromNetwork(url).install();

final InferenceModel model = await FlutterGemma.getActiveModel(maxTokens: 1024);
```

Sessions, chats, streaming and the common traps work as in the flutter-gemma-inference skill — except that `openSession` / `openChat` (its concurrent-conversation pattern) work on Android and iOS only; on web they throw `UnsupportedError`.

## iOS

`ios/Podfile`, declared once:

```ruby
platform :ios, '16.0'
use_frameworks! :linkage => :static
```

With Swift Package Manager, also set **iOS Deployment Target** to 16.0 on the Runner target in Xcode. This package ships no Swift package manifest, so the app gets an `ios/Podfile` either way.

Core and the other engines build from iOS 15.0. If the app does not use `.task` models, leave this package out and stay on 15.

Large models also need **Extended Virtual Addressing** and **Increased Memory Limit**, added in Xcode under **Signing & Capabilities**, or the app is killed for memory.

## Images and audio

```dart
final model = await FlutterGemma.getActiveModel(maxTokens: 4096, supportImage: true);
final chat = await model.createChat(supportImage: true);
await chat.addQueryChunk(
  Message(text: 'Describe this image.', isUser: true, imageBytes: bytes),
);
```

On Android and iOS, a chat without `supportImage: true` drops the image and the model answers the text alone. On web the chat follows the model: an image sent to a model loaded without `supportImage: true` throws `ArgumentError`.

Audio input works on Android and iOS with a model that takes audio, such as Gemma 3n.

## Bounding output

```dart
final session = await model.createSession();
await session.addQueryChunk(Message(text: prompt, isUser: true));
final reply = StringBuffer();
var produced = 0;
await for (final token in session.getResponseAsync()) {
  reply.write(token);
  if (++produced >= 200) {
    await session.stopGeneration();
    break;
  }
}
await session.close();
```

## Web

Add to `web/index.html` `<head>`, before Flutter boots:

```html
<script type="module">
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
<script src="cache_api.js"></script>
<script src="opfs_helper.js"></script>
```

Pin the version — an unpinned import takes whatever was published last. Copy `cache_api.js` and `opfs_helper.js` from the `flutter_gemma` package's `web/` directory into the app's `web/`; find it with `grep -A1 '"name": "flutter_gemma"' .dart_tool/package_config.json`.

Web is GPU-only. Models over about 2 GB need OPFS streaming storage:

```dart
await FlutterGemma.initialize(
  webStorageMode: WebStorageMode.streaming,
  inferenceEngines: [MediaPipeEngine()],
);
```

## Android

Text inference runs on `arm64-v8a`, `x86_64` and `armeabi-v7a`. The release build needs `<uses-permission android:name="android.permission.INTERNET"/>` in `android/app/src/main/AndroidManifest.xml` to download a model — Flutter's template declares it only for debug and profile builds.
