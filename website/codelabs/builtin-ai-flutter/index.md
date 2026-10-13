author: Sasha Denisov
summary: Build a Flutter chat with the AI model supplied by the operating system
id: builtin-ai-flutter
categories: flutter, ai, on-device, built-in-ai
environments: android, ios, macos, windows, web
status: Published

# Built-in AI in Flutter: Your First Prompt with the OS Model

## Overview
Duration: 3

### What you'll build

A small Flutter app that asks the operating system for its built-in language
model and streams one answer onto the screen. There is no model file in the app
and no Hugging Face download:

```text
Flutter UI
    ↓
flutter_edge_ai
    ↓
flutter_edge_ai_builtin_ai
    ↓
Gemini Nano · Apple Foundation Models · Phi Silica · browser Prompt API
```

The platform owns the weights. Your Dart code checks whether they are available,
prepares them when necessary, and then talks through the same
`InferenceModelSession` interface on every platform.

### What you'll learn

* how `flutter_edge_ai` and `flutter_edge_ai_builtin_ai` fit together
* why built-in AI must be checked on the device at run time
* how to prepare an OS model without downloading a model file yourself
* how `ModelFileType.builtIn` routes a model to `BuiltInAiEngine`
* how to send a prompt, stream the answer and close native resources

### What you'll need

* Flutter 3.44 or newer and Dart 3.12 or newer
* one device that exposes a supported built-in model:
  * Android: Gemini Nano through ML Kit GenAI / AICore (`minSdk 26`)
  * iOS or macOS: Apple Foundation Models with Apple Intelligence enabled
  * Windows: Phi Silica through Windows AI Foundry
  * web: Chrome or Edge with the Prompt API enabled

Availability belongs to the actual device, not the Flutter target. An app can
compile successfully on an older or unsupported device and receive an
`unavailable...` status at run time. Linux has no OS built-in model.

### Get the code

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/builtin-ai-flutter
ls
```

```text
step_01_starter/       register the engine
step_02_availability/  check and prepare the OS model
step_03_first_prompt/  send one prompt
complete/              stream the finished answer
```

## Step 1: Register the built-in engine
Duration: 8

### Add the packages

Start with a Flutter app and add two packages:

```bash
flutter create builtin_ai_codelab
cd builtin_ai_codelab
flutter pub add flutter_edge_ai
flutter pub add flutter_edge_ai_builtin_ai
```

`flutter_edge_ai` supplies the common model, session and message APIs. It does
not ship an inference runtime. `flutter_edge_ai_builtin_ai` is the engine that
maps those APIs onto the model exposed by the current operating system or
browser.

On Android, set the application's minimum SDK to 26 in
`android/app/build.gradle.kts`:

```kotlin
defaultConfig {
    minSdk = 26
}
```

### Initialize once

Import both packages and register the engine before `runApp`:

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterEdgeAi.initialize(
    inferenceEngines: const [BuiltInAiEngine()],
  );

  runApp(const BuiltInAiApp());
}
```

Registration does not open a model and does not download anything. It tells
the core which engine can handle a model whose file type is
`ModelFileType.builtIn`.

Run `step_01_starter`. The app has an engine, but it does not assume the current
device has a usable model. That question comes next.

## Step 2: Ask the device
Duration: 12

Built-in AI depends on hardware, OS version, user settings and sometimes an OS
feature download. Check it at run time:

```dart
final status = await BuiltInAi.availability();
```

The important states are:

| Status | Meaning |
|---|---|
| `available` | The model is ready now |
| `downloadable` | This device supports it, but the OS must fetch it |
| `downloading` | The OS is already preparing it |
| `unavailable...` | This device, OS or configuration cannot use it |

Do not convert an unavailable state into a download spinner. It cannot be fixed
by waiting. Show a clear message or continue to another engine.

### Prepare the feature

For `downloadable` or `downloading`, let the operating system finish preparing
the feature:

```dart
await BuiltInAi.ensureReady(
  onProgress: (percent) {
    setState(() => _progress = percent);
  },
);
```

`ensureReady` returns immediately when the model is already available. It
throws `BuiltInAiUnavailableException` for an unavailable state and times out
if preparation never finishes.

> **Web requires the button tap.** Call `ensureReady()` directly from a user
> gesture, with no other awaited operation before it. Chrome and Edge refuse to
> start an on-device model download without that gesture. The
> `Prepare built-in AI` button in `step_02_availability` is the pattern.

Also ask whether this platform has a built-in model identity at all:

```dart
final spec = BuiltInAiModels.forCurrentPlatform;
if (spec == null) {
  // Linux and Fuchsia have no built-in model.
}
```

Run `step_02_availability`. On a supported device the card displays the real
OS status and offers preparation only when waiting can help.

## Step 3: Send the first prompt
Duration: 14

### Select the platform model

After `ensureReady`, get the ready-made specification and register its identity
with core:

```dart
final spec = BuiltInAiModels.forCurrentPlatform;
if (spec == null) {
  throw UnsupportedError('This platform has no built-in AI model.');
}

await FlutterEdgeAi.installModel(
  modelType: spec.modelType,
  fileType: ModelFileType.builtIn,
).fromBundled(spec.name).install();
```

The word `install` is deliberately uniform across the SDK, but no weights are
copied here. `ModelFileType.builtIn` tells core that the OS owns the model and
routes it to `BuiltInAiEngine`; `spec.name` records which platform identity is
active.

### Open a session

```dart
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
final session = await model.createSession();
```

`maxTokens` is the entire context window—prompt, history and answer—not just an
answer-length limit.

### Ask once

```dart
await session.addQueryChunk(
  Message.text(text: prompt, isUser: true),
);

final answer = await session.getResponse();
```

`isUser: true` matters: `Message.isUser` defaults to false. Leaving it out
marks the prompt as a model message and can produce an empty or incorrect turn.

Run `step_03_first_prompt`, tap **Start built-in AI**, and ask the pre-filled
question. Preparation and model creation stay separate from generation, so an
error message can say which phase failed.

## Step 4: Stream and clean up
Duration: 8

A model can take a while to finish. Replace the one-shot `getResponse()` with a
stream so the first words appear immediately:

```dart
final answer = StringBuffer();

await for (final chunk in session.getResponseAsync()) {
  answer.write(chunk);
  setState(() => _answer = answer.toString());
}
```

Each string is the new chunk only. Append it; do not replace the accumulated
answer with the latest chunk.

Sessions and models own native resources. Close both when the page goes away:

```dart
@override
void dispose() {
  _session?.close().catchError((Object _) {});
  _model?.close().catchError((Object _) {});
  _prompt.dispose();
  super.dispose();
}
```

Run the `complete` app. It now follows the whole built-in path:

```text
button tap → ensure ready → select OS identity → open session → stream answer
```

No application code names Gemini Nano, Apple Foundation Models or Phi Silica.
The current platform chooses that implementation behind the same Dart API.

## Next steps
Duration: 3

This tutorial stops at one small, understandable success path. A production app
should also offer another route when built-in AI is unavailable.

Continue with [Inference Engines in Flutter](/codelabs/inference-engines-flutter-gemma)
to register LiteRT-LM beside `BuiltInAiEngine` and fall back to a downloaded
open model. See [Built-in AI](/docs/builtin-ai) for platform requirements,
browser setup, function calling and capability differences.
