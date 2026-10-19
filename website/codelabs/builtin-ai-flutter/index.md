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
  12.0 yourself. The step apps use Swift Package Manager, so CocoaPods is not
  needed.
* one device whose built-in model is usable:
  * **Android:** a phone on
    [Google's Prompt API device list](https://developers.google.com/ml-kit/genai#prompt-device),
    with a locked bootloader. Emulators are not supported. After a new phone is
    set up, AICore can need minutes to hours before the model is ready.
  * **iOS or macOS:** iOS or macOS 26 on a device that supports Apple
    Intelligence, with Apple Intelligence turned on, and the app built with
    Xcode 26. An app built with an older Xcode reports the OS as too old.
  * **Web:** desktop Chrome 148 or newer on Windows, macOS 13+, Linux or
    ChromeOS Plus, with 22 GB of free disk, either a GPU with more than 4 GB
    of VRAM or 16 GB of RAM and 4 CPU cores, and an unmetered connection for
    the first download.

Availability belongs to the actual device, not the Flutter target. An app can
compile on an older or unsupported device and receive an `unavailable…` status
at run time. Linux has no OS built-in model. Windows has Phi Silica, but only a
packaged app with package identity and the `systemAIModels` capability, the
Windows App Runtime and, on the stable channel, a Limited Access Feature token
can reach it. `flutter run` gives it none of these, so this codelab does not
cover Windows: there the app reports `unavailableOther`.

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
complete/              stream the answer, stop it
```

Each step is a complete app that grows the one before it. All four show the
same page, `BuiltInAiPage`: a device status card, then a prompt field and an
**Ask** button that stay disabled until there is a model.

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
`ModelFileType.builtIn`. Below it in the same file, `BuiltInAiPage` lays out
the page every later step fills in: the **Device status** card with a
placeholder, and a disabled composer.

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

On an iPhone, run `flutter pub get` in the step's folder first (otherwise
Xcode reports missing files), then open `ios/Runner.xcworkspace` in Xcode.
Under **Signing & Capabilities** pick your own team and change the bundle
identifier: the one the apps ship with, `dev.flutteredgeai.builtinai`, can be
registered to one team only. Every step is its own Xcode project with the same
identifier, so do this once per step you run.

On the web, serve the app and open it in your own Chrome:

```bash
flutter run -d web-server --web-port=8080
```

Then open `http://localhost:8080` in your everyday Chrome profile. Open it as
`localhost`, not through the computer's LAN address: the Prompt API is meant
for secure contexts, and a plain-HTTP LAN address is not one. Since Chrome 148
the Prompt API is part of stable Chrome, with no flag and no origin-trial
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
states mean the model cannot run right now: some need the user to change
something, others clear on their own. One value also means different things on
different platforms, so the app gives each platform its own remedy in an
exhaustive `switch`:

```dart
String statusMessage(BuiltInAiAvailability status) => switch ((status, _host)) {
  (BuiltInAiAvailability.available, _) => 'Built-in AI is ready.',
  (BuiltInAiAvailability.downloadable, _Host.web) =>
    'Chrome has to download its model once, several GB, over an unmetered '
        'connection. Choose Prepare to start.',
  // … the other downloadable and downloading arms
  (BuiltInAiAvailability.unavailableDeviceUnsupported, _Host.web) =>
    'This browser has no Prompt API. Open the page at localhost or over '
        'HTTPS in desktop Chrome 148 or newer.',
  // … the other unavailableDeviceUnsupported arms
  (BuiltInAiAvailability.unavailableOsTooOld, _Host.apple) =>
    'Built-in AI needs iOS or macOS 26, and an app built with Xcode 26.',
  // … the other unavailableOsTooOld arm
  (BuiltInAiAvailability.unavailableDisabled, _Host.apple) =>
    'Turn on Apple Intelligence in Settings, then check again.',
  // … the other unavailableDisabled arm
  (BuiltInAiAvailability.unavailableOther, _Host.android) =>
    'Google AICore is missing, out of date or not set up yet, or this is an '
        'emulator. Update AICore from the Play Store, then reinstall this '
        'app. On a phone set up recently, AICore can need minutes to hours, '
        'and a restart can help: check again later.',
  // … the other unavailableOther arms
};
```

`lib/main.dart` has every arm; copy it from there. The cases worth knowing
(— means the platform never reports that status):

| Status | Web | Android | iOS / macOS |
|---|---|---|---|
| `unavailableDeviceUnsupported` | no Prompt API in this browser, or not a secure context | not on Google's list, an unlocked bootloader, **or not set up yet** | no Apple Intelligence |
| `unavailableOsTooOld` | — | — | OS before 26, **or an app built before Xcode 26** |
| `unavailableDisabled` | — | — | Apple Intelligence off |
| `unavailableOther` | on-device AI off in Chrome's Settings → System or by the `GenAILocalFoundationalModelSettings` policy, or below the disk, GPU or RAM floor | AICore missing, old or not set up yet (update it, then reinstall the app), or an emulator | the probe failed; check again |

Because some of these clear on their own, the app never treats a status as
final. It asks again when the reader taps **Check again** and whenever the app
comes back to the foreground, since the reader may have just changed a setting.
To hear about the foreground, the page's state mixes in
`WidgetsBindingObserver` and registers itself:

```dart
class _BuiltInAiPageState extends State<BuiltInAiPage>
    with WidgetsBindingObserver {
  // …

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAvailability();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    final probe = ++_probe;
    final status = await BuiltInAi.availability();
    if (mounted && probe == _probe) _showStatus(status);
  }

  /// Only a probe writes the card. A new status replaces whatever error
  /// described the old one.
  void _showStatus(BuiltInAiAvailability status) {
    setState(() {
      if (status != _availability) _error = null;
      _availability = status;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
```

A probe can take up to 20 seconds, and the start-up probe, a resume and a tap
can overlap. `_probe` numbers them, so one that returns late cannot overwrite a
newer answer.

### Prepare the model

For `downloadable` and `downloading`, the card offers **Prepare** instead of
starting a download on its own: the OS download is several GB, so the user
chooses it. On Apple there is nothing to start (turning Apple Intelligence on
started it), so the button only waits.

Step 2 adds `import 'dart:async';` at the top of `lib/main.dart`, for
`TimeoutException` here and `unawaited` later:

```dart
// Keep this call directly attached to the tap for the web user-gesture gate.
Future<void> _prepare() async {
  setState(() {
    _error = null;
    _progress = null;
    _preparing = true;
  });
  String? failure;
  try {
    await BuiltInAi.ensureReady(
      onProgress: (percent) {
        if (mounted) setState(() => _progress = percent);
      },
    );
    // ensureReady returns only once the model is available, so it answers
    // like a probe.
    _probe++;
    if (mounted) _showStatus(BuiltInAiAvailability.available);
  } on BuiltInAiUnavailableException catch (error) {
    failure = error.status == BuiltInAiAvailability.downloadable
        // Still downloadable, so the download never started: on the web,
        // Chrome starts it only from a tap.
        ? 'The download did not start. Choose Prepare again.'
        : 'Preparing stopped: a status check failed. If the card still '
              'offers Prepare, choose it to try again.';
  } on TimeoutException {
    failure =
        'The model is still not ready after 10 minutes. The download may '
        'still be running: check again later.';
  } catch (error, stackTrace) {
    failure = 'Could not prepare: $error';
    _report(error, stackTrace, 'while preparing the built-in AI model');
  } finally {
    if (mounted) {
      setState(() {
        _preparing = false;
        _progress = null;
      });
    }
  }
  if (failure != null) await _failed(failure);
}
```

`ensureReady` returns once the model is available, so the card can say so at
once. It can fail three ways, and the app catches each one:

* `BuiltInAiUnavailableException`: the OS refused, or the model became
  unavailable during the download. The app does not show the exception's own
  text, which names Dart types and calls the reader cannot make.
* `TimeoutException` after 10 minutes. Several GB can take longer, and the
  download may still be running.
* anything else, such as a download Android refused to start.

Every failure goes through `_failed`, which asks the device again and only
then shows what failed. In that order, the new status cannot wipe the message.
A probe can take up to 20 seconds, so `_rechecking` keeps the buttons off and
a progress bar on until it returns (the page's `working` includes it):

```dart
/// Set while a failed action waits for the probe that explains it.
bool _rechecking = false;

/// An action failed: ask the device again, then say what failed, so the new
/// status cannot wipe the message.
Future<void> _failed(String message) async {
  // A probe can take up to 20 seconds; keep the buttons off meanwhile.
  if (mounted) setState(() => _rechecking = true);
  await _checkAvailability();
  if (mounted) {
    setState(() {
      _rechecking = false;
      _error = message;
    });
  }
}
```

A failure nobody expected is also reported, so it reaches the debug console
and any crash reporter the app installs:

```dart
void _report(Object error, StackTrace stackTrace, String context) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'builtin_ai_codelab',
      context: ErrorDescription(context),
    ),
  );
}
```

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
action that can help. The composer stays disabled: there is no model yet.

## Step 3: Send the first prompt
Duration: 14

Open `step_03_first_prompt`. It keeps the card from Step 2 and adds **Start**,
which the card offers only while the status is `available`.

### Select the platform model

```dart
Future<void> _start() async {
  final spec = BuiltInAiModels.forCurrentPlatform;
  if (spec == null || _availability != BuiltInAiAvailability.available) {
    return;
  }

  setState(() {
    _busy = true;
    _error = null;
  });
  String? failure;
  try {
    await FlutterEdgeAi.installModel(
      modelType: spec.modelType,
      fileType: ModelFileType.builtIn,
    ).fromBundled(spec.name).install();
    final model = await FlutterEdgeAi.getActiveModel(maxTokens: 4096);
    if (!mounted) {
      await model.close();
      return;
    }
    setState(() => _model = model);
  } on BuiltInAiUnavailableException {
    // The status changed since the last probe; the probe shows the new one.
    failure = 'Could not start: the model is no longer ready.';
  } catch (error, stackTrace) {
    failure = 'Could not start: $error';
    _report(error, stackTrace, 'while opening the built-in AI model');
  } finally {
    if (mounted) setState(() => _busy = false);
  }
  if (failure != null) await _failed(failure);
}
```

The word `install` is deliberately uniform across the SDK, but no weights are
copied here. `ModelFileType.builtIn` tells core that the OS owns the model and
routes it to `BuiltInAiEngine`; `spec.name` records which platform identity is
active.

`maxTokens` is the entire context window (prompt, history and answer), not an
answer-length limit.

The status can change between the probe and the tap: the OS may have started
downloading again. `getActiveModel` then throws
`BuiltInAiUnavailableException`, and `_failed` puts the new status on the card.

The prompt field and **Ask** are enabled only while the model is open, the
status is `available` and nothing else is running. In `build`:

```dart
final working = _busy || _preparing || _rechecking;
final canAsk = _model != null && ready && !working;
```

The `TextField` takes `enabled: canAsk` and **Ask** takes
`onPressed: canAsk ? _ask : null`. If the reader turns Apple
Intelligence off while the app is open, the next resume disables them and the
card shows **Check again**.

### Ask once

Every Ask opens a fresh session, so an earlier answer cannot shape a later one
and hidden history cannot fill the context window:

```dart
Future<void> _ask() async {
  final model = _model;
  if (model == null || _busy) return;
  final text = _prompt.text.trim();
  if (text.isEmpty) {
    setState(() => _error = 'Type a question first.');
    return;
  }

  setState(() {
    _busy = true;
    _error = null;
    _answer = '';
  });

  InferenceModelSession? session;
  String? failure;
  try {
    session = await model.createSession();
    await session.addQueryChunk(Message.text(text: text, isUser: true));
    final answer = await session.getResponse();
    if (mounted) setState(() => _answer = answer);
    if (mounted && answer.trim().isEmpty) {
      setState(
        () => _error =
            'The model returned an empty answer. Rephrase the question and '
            'ask again.',
      );
    }
  } on BuiltInAiUnavailableException {
    failure = 'The model is no longer ready.';
  } catch (error, stackTrace) {
    failure = 'The request failed: $error';
    _report(error, stackTrace, 'while generating an answer');
  } finally {
    if (session != null) {
      try {
        await session.close();
      } catch (error, stackTrace) {
        _report(error, stackTrace, 'while closing the built-in AI session');
      }
    }
    if (mounted) {
      setState(() {
        _busy = false;
        if (failure != null) _answer = '';
      });
    }
  }
  if (failure != null) await _failed(failure);
}
```

The session opens inside the `try`, so a failure to open it is caught too. A
failing `close()` is reported on its own and cannot hide the error that came
before it. Any failure checks the card again: on Apple, a model that went away
arrives as a generation error, not as `BuiltInAiUnavailableException`.

The error message is the OS's own. A refusal by the model's safety filter or a
full context fails the same way again. Android lets only the app in the
foreground generate, so that error goes away once the app is back in front,
and a per-app quota error clears after a wait. The message tells the reader
which one it was.

The model is sampled greedily, so asking the same question again gives the
same answer. After an empty answer, the app asks the reader to rephrase.

`isUser: true` marks the text as the user's turn. The built-in engine sends
the text as it is today, but other `flutter_edge_ai` engines build a chat
template from it, and `Message.isUser` defaults to false, so keep it.

### Own the model

The model lives as long as the page, so `dispose` stops observing the
lifecycle and closes it. `close()` returns a future that `dispose` cannot
await; `unawaited` (from `dart:async`) says so, and `catchError` reports a
failed close instead of losing it:

```dart
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

Run `step_03_first_prompt`, prepare the model if the card asks for it, tap
**Start built-in AI**, and ask the pre-filled question.

## Step 4: Stream the answer
Duration: 8

Open `complete`. `_ask` and the Ask button change: the answer streams, so
the first words appear immediately, and a **Stop** button can end it.

The page keeps how to stop the current answer in a new field, null while
nothing streams:

```dart
/// Ends the answer being streamed; null while nothing streams.
Future<void> Function()? _stop;
```

In `_ask`, the stream replaces `getResponse()`:

```dart
final answer = StringBuffer();
final finished = Completer<void>();
final subscription = session.getResponseAsync().listen(
  (chunk) {
    answer.write(chunk);
    if (mounted) setState(() => _answer = answer.toString());
  },
  onError: finished.completeError,
  onDone: finished.complete,
  cancelOnError: true,
);
final streaming = session;
var stopped = false;
_stop = () async {
  stopped = true;
  await subscription.cancel();
  if (!finished.isCompleted) finished.complete();
  try {
    // Cancelling only stops listening; this stops the model decoding.
    await streaming.stopGeneration();
  } catch (error, stackTrace) {
    _report(error, stackTrace, 'while stopping the answer');
  }
};
if (mounted) setState(() {});
await finished.future;
if (mounted && !stopped && answer.toString().trim().isEmpty) {
  // … the same empty-answer message as in Step 3
}
```

Each string is the new chunk only. Append it; do not replace the accumulated
answer with the latest chunk. If the stream fails halfway, the `catch` from
Step 3 clears the partial answer.

The `finally` from Step 3 sets `_stop` back to null: add `_stop = null;` as
its first line.

In `build`, read the field once (`final stop = _stop;` next to `working`) and
show **Stop** in place of **Ask** while it is set:

```dart
if (stop != null)
  OutlinedButton(onPressed: stop, child: const Text('Stop'))
else
  FilledButton(
    onPressed: canAsk ? _ask : null,
    child: const Text('Ask'),
  ),
```

A model can keep generating for a long time; **Stop** keeps what has arrived,
stops the model and closes the session as usual.

Run the `complete` app. It follows the whole built-in path, one tap per step:

```text
launch / resume / Check again → availability() → status card
Prepare tap                   → ensureReady()   → status card
Start tap                     → install builtIn → getActiveModel()
Ask tap                       → createSession() → stream answer → close()
```

No model or session code names Gemini Nano or Apple Foundation Models.
The current platform chooses that implementation behind the same Dart API.

### Test it

`complete/test/widget_test.dart` drives the app against a fake OS model
(`FakeLocalAiHost` from `flutter_local_ai`): Prepare and its 10-minute
timeout, Start, Ask, a failure halfway through an answer, Stop and a resume.

`complete/integration_test/builtin_ai_test.dart` calls the same APIs as the
app, in the same order, on a real device. It does not drive the UI, and it
fails unless an answer comes back:

```bash
cd complete
flutter test integration_test/builtin_ai_test.dart -d <device-id>
```

On a device without built-in AI, pass
`--dart-define=EXPECT_UNAVAILABLE=true` to check that it is refused with
`BuiltInAiUnavailableException` instead. On an Android phone whose model is
still `downloadable`, the test starts the download and waits up to 10
minutes; keep the screen on with `adb shell svc power stayon true`.

## What's next
Duration: 3

This tutorial stops at one small, understandable success path. A production app
should also offer another route when built-in AI is unavailable.

Continue with [Inference Engines in Flutter](/codelabs/inference-engines-flutter-gemma)
to register LiteRT-LM beside `BuiltInAiEngine` and fall back to a downloaded
open model. See [Built-in AI](/docs/builtin-ai) for platform requirements,
function calling and capability differences.
