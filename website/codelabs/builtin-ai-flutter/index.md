author: Sasha Denisov
summary: Build a Flutter chat with the AI model supplied by the operating system
id: builtin-ai-flutter
categories: flutter, ai, on-device, built-in-ai
environments: android, ios, macos, web
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
Gemini Nano · Apple Foundation Models · browser Prompt API
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

* Flutter 3.47 or newer and Dart 3.12 or newer
* one device that exposes a supported built-in model:
  * Android: a device on [Google's Prompt API support list](/docs/builtin-ai)
    with a locked bootloader and AICore (`minSdk 26`); emulators are not
    supported, and provisioning after setup can take minutes or hours
  * iOS or macOS: OS 26, Apple Intelligence enabled, and an app built with
    Xcode 26
  * web: desktop Chrome with the Prompt API enabled and the hardware described
    in [Built-in AI](/docs/builtin-ai)

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
  webStorageMode: WebStorageMode.streaming,
  );

  runApp(const BuiltInAiApp());
}
```

Registration does not open a model and does not download anything. It tells
the core which engine can handle a model whose file type is
`ModelFileType.builtIn`.

Run `step_01_starter`. The app has an engine, but it does not assume the current
device has a usable model. That question comes next.

For web, copy `cache_api.js` and `opfs_helper.js` from
`packages/flutter_edge_ai/web/` into the app's `web/` directory and load
them before `flutter_bootstrap.js`, as shown by every step app's
`web/index.html`. Run with:

```bash
flutter run -d web-server --web-port=8080
```

Open the URL in your regular desktop Chrome profile. Enable
`chrome://flags/#prompt-api-for-gemini-nano` for local development; a
deployed site needs an origin-trial token. `flutter run -d chrome` uses a
fresh profile where that flag is absent.

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
| `unavailableDeviceUnsupported` | Use a supported physical device |
| `unavailableOsTooOld` | Update the operating system |
| `unavailableDisabled` | Enable Apple Intelligence or the system AI feature |
| `unavailableOther` | Check platform setup and try the probe again |

Do not convert an unavailable state into a download spinner. It cannot be fixed
by waiting. Show a clear message or continue to another engine.

### Prepare the feature

For `downloadable` or `downloading`, let the operating system finish preparing
the feature:

```dart
// Call from the Prepare button so the user consents to a potentially
// multi-gigabyte OS download.
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

Only offer **Start** when availability is `available`. For `downloadable`
or `downloading`, retain the status card and offer **Prepare** with the size
notice instead. Re-check after preparation, when the app resumes, or when the
reader taps **Check again**.

After the status becomes available, get the ready-made specification and register its identity
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
```

`maxTokens` is the entire context window—prompt, history and answer—not just an
answer-length limit.

### Ask once

```dart
final session = await model.createSession();
try {
  await session.addQueryChunk(
    Message.text(text: prompt, isUser: true),
  );
  final answer = await session.getResponse();
  if (answer.trim().isEmpty) {
    // Tell the reader that no answer was produced.
  }
} finally {
  await session.close();
}
```

`isUser: true` matters: `Message.isUser` defaults to false. Leaving it out
marks the prompt as a model message and can produce an empty or incorrect turn.

Run `step_03_first_prompt`, prepare the model if the OS requests it, tap
**Start built-in AI**, and ask the pre-filled question. Every Ask uses a fresh
session, so hidden history cannot shape later answers or fill the context.

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

Sessions and models own native resources. The step app closes each fresh
session after its answer and reports cleanup failures with
`FlutterError.reportError`. When the page goes away, it closes the model:

```dart
@override
void dispose() {
  final model = _model;
  _model = null;
  if (model != null) {
    unawaited(model.close().catchError((Object error, StackTrace stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stackTrace),
      );
    }));
  }
  _prompt.dispose();
  super.dispose();
}
```

Run the `complete` app. It now follows the whole built-in path:

```text
button tap → ensure ready → select OS identity → open session → stream answer
```

No application code names Gemini Nano or Apple Foundation Models.
The current platform chooses that implementation behind the same Dart API.

## What's next
Duration: 3

This tutorial stops at one small, understandable success path. A production app
should also offer another route when built-in AI is unavailable.

Continue with [Inference Engines in Flutter](/codelabs/inference-engines-flutter-gemma)
to register LiteRT-LM beside `BuiltInAiEngine` and fall back to a downloaded
open model. See [Built-in AI](/docs/builtin-ai) for platform requirements,
browser setup, function calling and capability differences.
