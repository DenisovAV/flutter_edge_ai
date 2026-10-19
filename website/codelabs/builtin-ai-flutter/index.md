author: Francesco Vezzani
summary: Build a Flutter app that prompts the AI model supplied by the operating system
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
Gemini Nano · Apple Foundation Models · Chrome Prompt API
```

The platform owns the weights. Your Dart code checks whether they are available,
asks the user before the OS downloads them, and then talks through the same
`InferenceModelSession` interface on every platform.

### What you'll learn

* why built-in AI must be checked on the device at run time, and what each
  answer means on each platform
* how to tell the user what to change when the model is unavailable
* how to ask before the OS downloads several GB, and what to show meanwhile
* how `ModelFileType.builtIn` routes a model to `BuiltInAiEngine`
* how to send a prompt, stream the answer and close native resources

### What you'll need

* Flutter 3.47 or newer. Its app template targets iOS 15 and macOS 12; with an
  older Flutter, raise the iOS deployment target to 15.0 and the macOS one to
  12.0 yourself.
* one device whose built-in model is usable:
  * **Android:** a phone on
    [Google's Prompt API device list](https://developers.google.com/ml-kit/genai#prompt-device),
    with a locked bootloader. Emulators are not supported. After a new phone is
    set up, AICore can need minutes to hours before the model is ready.
  * **iOS or macOS:** iOS or macOS 26 on a device that supports Apple
    Intelligence, with Apple Intelligence turned on, and the app built with
    Xcode 26. An app built with an older Xcode reports the OS as too old.
  * **Web:** desktop Chrome 148 or newer on Windows, macOS 13+, Linux or
    ChromeOS Plus, with 22 GB of free disk and either a GPU with more than 4 GB
    of VRAM or 16 GB of RAM and 4 CPU cores.

Availability belongs to the actual device, not the Flutter target. An app can
compile on an older or unsupported device and receive an `unavailable…` status
at run time. Linux has no OS built-in model. Windows has Phi Silica, but only an
app packaged with package identity can reach it, which `flutter run` does not
give it, so this codelab does not cover Windows: there the app reports
`unavailableOther`.

### Get the code

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/builtin-ai-flutter
ls
```

```text
step_01_starter/       the engine is registered
step_02_availability/  ask the device, prepare the model
step_03_first_prompt/  start the model and ask once
complete/              stream the answer
```

Each step is a complete app that grows the one before it.

## Step 1: Register the built-in engine
Duration: 8

Open `step_01_starter`. It already depends on both packages:

```yaml
dependencies:
  flutter_edge_ai: ^2.3.0
  flutter_edge_ai_builtin_ai: ^0.3.5
```

`flutter_edge_ai` supplies the common model, session and message APIs. It does
not ship an inference runtime. `flutter_edge_ai_builtin_ai` is the engine that
maps those APIs onto the model exposed by the current operating system or
browser.

`lib/main.dart` registers the engine before `runApp`:

```dart
import 'package:flutter/material.dart';
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
`ModelFileType.builtIn`. `BuiltInAiApp` is the page shell below it in the same
file, with a composer that stays disabled until there is a model.

The app's build settings are already set for the packages: Android's
`android/app/build.gradle.kts` sets `minSdk = 26`, the lowest Android version
the package builds for (the device list above is what decides whether a phone
runs the model). The step apps' `web/index.html` loads `cache_api.js` and
`opfs_helper.js` before `flutter_bootstrap.js`; in an app of your own, copy them
from the resolved `flutter_edge_ai` package as the
[getting-started codelab](/codelabs/getting-started-flutter-gemma) shows.

### Run it

On Android, macOS or a simulator:

```bash
cd step_01_starter
flutter run
```

On an iPhone, open `ios/Runner.xcworkspace` in Xcode first. Under **Signing &
Capabilities** pick your own team and change the bundle identifier: the one the
app ships with, `dev.flutteredgeai.builtinai`, can be registered to one team
only.

On the web, serve the app and open it in your own Chrome:

```bash
flutter run -d web-server --web-port=8080
```

Then open `http://localhost:8080` in your everyday Chrome profile. Since Chrome
148 the Prompt API is part of stable Chrome, with no flag and no origin-trial
token. Avoid `flutter run -d chrome`: it starts a temporary profile that is
deleted on exit, so Chrome downloads its model again on every run. If Chrome
reports the model as unavailable after a download, restart Chrome;
`chrome://on-device-internals` shows the model's state.

## Step 2: Ask the device
Duration: 12

Open `step_02_availability`. Built-in AI depends on hardware, OS version, user
settings and sometimes an OS download, so the app asks at run time:

```dart
final status = await BuiltInAi.availability();
```

`downloadable` and `downloading` are the two states worth waiting on
(`status.isTransient`). `available` means ready now. The four `unavailable…`
states each need the user to change something, and one value means different
things on different platforms, so the app gives each platform its own remedy
in an exhaustive `switch`:

```dart
String statusMessage(BuiltInAiAvailability status) => switch ((status, _host)) {
  (BuiltInAiAvailability.available, _) => 'Built-in AI is ready.',
  (BuiltInAiAvailability.downloadable, _Host.web) =>
    'Chrome has to download its model once, several GB. '
        'Choose Prepare to start.',
  // …
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _Host.web) =>
    'This browser has no Prompt API. Open the page in desktop Chrome 148 '
        'or newer.',
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _Host.android) =>
    "AICore reports Gemini Nano as unavailable: this phone is not on Google's "
        'Prompt API device list, or AICore has not finished setting it up. '
        'On a listed phone, stay online and check again later.',
  (BuiltInAiAvailability.unavailableOsTooOld, _Host.apple) =>
    'Built-in AI needs iOS or macOS 26, and an app built with Xcode 26.',
  (BuiltInAiAvailability.unavailableDisabled, _Host.apple) =>
    'Turn on Apple Intelligence in Settings, then check again.',
  (BuiltInAiAvailability.unavailableOther, _Host.web) =>
    'Chrome cannot run its model on this computer. It needs 22 GB of free '
        'disk, and a GPU with more than 4 GB of VRAM or 16 GB of RAM and '
        '4 CPU cores.',
  (BuiltInAiAvailability.unavailableOther, _Host.android) =>
    'Google AICore is missing or out of date, or this is an emulator. '
        'Update AICore from the Play Store, then check again.',
  // …
};
```

The file has every arm. The cases worth knowing:

| Status | Web | Android | iOS / macOS |
|---|---|---|---|
| `unavailableDeviceUnsupported` | no Prompt API in this browser | not on Google's list, **or not set up yet** | no Apple Intelligence |
| `unavailableOsTooOld` | old Chrome | old OS | OS before 26, **or an app built before Xcode 26** |
| `unavailableDisabled` | turned off by policy | turned off | Apple Intelligence off |
| `unavailableOther` | under the disk, GPU or RAM floor | AICore missing or old, or an emulator | the probe failed; the console says why |

Some of these clear on their own, so the app never treats a status as final.
It asks again when the reader taps **Check again** and whenever the app comes
back to the foreground, since the reader may have just changed a setting:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) _checkAvailability();
}

Future<void> _checkAvailability() async {
  final probe = ++_probe;
  final status = await BuiltInAi.availability();
  if (mounted && probe == _probe) _showStatus(status);
}

void _showStatus(BuiltInAiAvailability status) {
  setState(() {
    if (status != _availability) _error = null;
    _availability = status;
  });
}
```

A probe can take up to 20 seconds, and the start-up probe, a resume and a tap
can overlap. `_probe` numbers them, so one that returns late cannot overwrite a
newer answer. A new status also clears the error that described the old one.

### Prepare the model

For `downloadable` and `downloading`, the card offers **Prepare** instead of
starting a download on its own: the OS download is several GB, so the user
chooses it. On Apple there is nothing to start (turning Apple Intelligence on
started it), so the button only waits.

```dart
// Keep this call directly attached to the tap for the web user-gesture gate.
Future<void> _prepare() async {
  setState(() {
    _error = null;
    _progress = null;
    _preparing = true;
  });
  try {
    await BuiltInAi.ensureReady(
      onProgress: (percent) {
        if (mounted) setState(() => _progress = percent);
      },
    );
  } on BuiltInAiUnavailableException catch (error) {
    _showUnavailable(error);
  } on TimeoutException {
    if (mounted) {
      setState(
        () => _error =
            'The model is still not ready after 10 minutes. The OS keeps '
            'preparing it in the background: check again later.',
      );
    }
  } catch (error, stackTrace) {
    if (mounted) setState(() => _error = 'Could not prepare: $error');
    _report(error, stackTrace, 'while preparing the built-in AI model');
  } finally {
    if (mounted) {
      setState(() {
        _preparing = false;
        _progress = null;
      });
      await _checkAvailability();
    }
  }
}
```

`ensureReady` returns once the model is available. It can fail three ways, and
the app catches each one:

* `BuiltInAiUnavailableException`: the OS refused, or the model became
  unavailable during the download. `_showUnavailable` shows the status it
  carries and checks again.
* `TimeoutException` after 10 minutes. Several GB can take longer, and the OS
  keeps going in the background.
* anything else, such as a download Android refused to start. The app shows it
  and reports it with `FlutterError.reportError`.

The progress bar stays indeterminate until the first progress event: Apple
never sends one, and Android only for a download this call started.

> **Web requires the button tap.** Call `ensureReady()` directly from a user
> gesture, with no other awaited operation before it. Chrome refuses to start
> an on-device model download without that gesture.

Linux has no built-in model at all, so there the card says so and shows no
buttons:

```dart
final unsupported = BuiltInAiModels.forCurrentPlatform == null;
```

Run `step_02_availability`. The card shows what this device answers and the one
action that can help.

## Step 3: Send the first prompt
Duration: 14

Open `step_03_first_prompt`. It keeps the card from Step 2 and adds **Start**,
which the card offers only while the status is `available`.

### Select the platform model

```dart
final spec = BuiltInAiModels.forCurrentPlatform;
if (spec == null || _availability != BuiltInAiAvailability.available) {
  return;
}
// …
await FlutterEdgeAi.installModel(
  modelType: spec.modelType,
  fileType: ModelFileType.builtIn,
).fromBundled(spec.name).install();
model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
```

The word `install` is deliberately uniform across the SDK, but no weights are
copied here. `ModelFileType.builtIn` tells core that the OS owns the model and
routes it to `BuiltInAiEngine`; `spec.name` records which platform identity is
active.

`maxTokens` is the entire context window (prompt, history and answer), not an
answer-length limit.

The prompt field and **Ask** appear only while the model is open *and* the
status is `available`. If the reader turns Apple Intelligence off while the app
is open, the next resume hides them and the card shows **Check again**.

### Ask once

Every Ask opens a fresh session, so an earlier answer cannot shape a later one
and hidden history cannot fill the context window:

```dart
InferenceModelSession? session;
try {
  session = await model.createSession();
  await session.addQueryChunk(Message.text(text: text, isUser: true));
  final answer = await session.getResponse();
  if (mounted) setState(() => _answer = answer);
  if (mounted && answer.trim().isEmpty) {
    setState(
      () => _error = 'The model returned an empty answer. Try again.',
    );
  }
} on BuiltInAiUnavailableException catch (error) {
  if (mounted) setState(() => _answer = '');
  _showUnavailable(error);
} catch (error, stackTrace) {
  if (mounted) {
    setState(() {
      _answer = '';
      _error = 'The request failed: $error';
    });
  }
  _report(error, stackTrace, 'while generating an answer');
} finally {
  if (session != null) {
    try {
      await session.close();
    } catch (error, stackTrace) {
      _report(error, stackTrace, 'while closing the built-in AI session');
    }
  }
  if (mounted) setState(() => _busy = false);
}
```

The session opens inside the `try`, so a failure to open it is caught too. A
failing `close()` is reported on its own and cannot hide the error that came
before it. The error message is the OS's own: a refusal by the model's safety
filter, a full context, or Android's rule that only an app in the foreground
may generate would all fail again, so "try again" would not help.

`isUser: true` matters: `Message.isUser` defaults to false. Leaving it out
marks the prompt as a model message and can produce an empty or incorrect turn.

Run `step_03_first_prompt`, prepare the model if the card asks for it, tap
**Start built-in AI**, and ask the pre-filled question.

## Step 4: Stream and clean up
Duration: 8

Open `complete`. The only change to `_ask` is that it streams the answer, so the
first words appear immediately:

```dart
final answer = StringBuffer();
await for (final chunk in session.getResponseAsync()) {
  answer.write(chunk);
  if (mounted) setState(() => _answer = answer.toString());
}
if (mounted && answer.toString().trim().isEmpty) {
  setState(
    () => _error = 'The model returned an empty answer. Try again.',
  );
}
```

Each string is the new chunk only. Append it; do not replace the accumulated
answer with the latest chunk. If the stream fails halfway, the `catch` from
Step 3 clears the partial answer.

The session closes after every answer. The model lives as long as the page, so
`dispose` stops observing the lifecycle and closes it:

```dart
import 'dart:async'; // for unawaited

@override
void dispose() {
  WidgetsBinding.instance.removeObserver(this);
  final model = _model;
  _model = null;
  if (model != null) {
    unawaited(
      model.close().catchError((Object error, StackTrace stackTrace) {
        _report(error, stackTrace, 'while closing the built-in AI model');
      }),
    );
  }
  _prompt.dispose();
  super.dispose();
}
```

Run the `complete` app. It follows the whole built-in path, one tap per step:

```text
launch / resume / Check again → availability() → status card
Prepare tap                   → ensureReady()   → re-check
Start tap                     → install builtIn → getActiveModel()
Ask tap                       → createSession() → stream answer → close()
```

No application code names Gemini Nano or Apple Foundation Models.
The current platform chooses that implementation behind the same Dart API.

`complete/integration_test/builtin_ai_test.dart` runs the same path on a real
device and fails unless an answer comes back:

```bash
cd complete
flutter test integration_test/builtin_ai_test.dart -d <device-id>
```

## What's next
Duration: 3

This tutorial stops at one small, understandable success path. A production app
should also offer another route when built-in AI is unavailable.

Continue with [Inference Engines in Flutter](/codelabs/inference-engines-flutter-gemma)
to register LiteRT-LM beside `BuiltInAiEngine` and fall back to a downloaded
open model. See [Built-in AI](/docs/builtin-ai) for platform requirements,
function calling and capability differences.
