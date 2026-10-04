author: Sasha Denisov
summary: Inference Engines in Flutter — From a Downloaded Model to Built-in AI
id: inference-engines-flutter-gemma
categories: flutter, ai, gemma, gemini-nano
environments: android, ios, macos, windows, linux, web
status: Published

# Inference Engines in Flutter: From a Downloaded Model to Built-in AI

## Overview
Duration: 3

### What you'll build

The chat app from the *Getting Started* codelab, taught to run on **two
engines** and to choose between them by itself:

* **LiteRT-LM**, which opens a `.litertlm` file you download — the engine you
  already have
* the **built-in model** — Gemini Nano on Android and in Chrome, Apple
  Foundation Models on iOS and macOS — which has no file at all, because the
  operating system (or the browser) owns the weights

By the end, the app probes the device at startup, uses the built-in model when
the OS ships one, and falls back to the downloaded model when it doesn't.

The code that talks to the model does not change once in the whole codelab.
Three functions — `_load`, `_send` and `dispose` in `chat_page.dart` — are
character-for-character the same in all four step directories and on both
engines; `diff` them and see. What does grow is the chrome around them: an app
bar menu in Step 2, an engine label beside it, a banner in Step 4. That is the
point.

### What you'll learn

* what an **engine** is in `flutter_edge_ai`, and why the core ships none
* how a model's `ModelFileType` is the entire "engine switch"
* that *installed* and *active* are different things — and that *installed* is
  not even a concept for a model the OS owns
* why built-in availability can only be asked at run time, and how to ask
* how to fail with a **typed** error so the app can choose a fallback instead
  of crashing

### What you'll need

* The finished app from
  [Getting Started with On-Device LLMs in Flutter](/codelabs/getting-started-flutter-gemma)
  — or just its `complete/` directory, which is this codelab's starter
* Anything the app runs on — all six Flutter platforms. The package can use a
  built-in model on five: **Android** (Pixel 9+, Galaxy S25+), **iOS** (iPhone 15 Pro+
  with Apple Intelligence on), **macOS** (an Apple-silicon Mac with Apple
  Intelligence on) and the **web** (desktop Chrome with the Prompt API enabled —
  `chrome://flags/#prompt-api-for-gemini-nano` for local development, an
  [origin trial](https://developer.chrome.com/origintrials) token for a real
  site), plus **Windows** through Windows AI Foundry. This codelab's model
  picker deliberately implements only the first four, so Windows exercises its
  downloaded-model fallback even though `flutter_edge_ai_builtin_ai` itself
  supports Windows. One of the implemented four lets you watch both engines
  answer
* On **Android**, an arm64 device or emulator: `flutter_edge_ai_litertlm` ships an
  arm64 library and nothing else, so a 32-bit or x86_64 image has no runtime to
  load. An Apple-silicon Mac's emulator is arm64
* Chrome has a hardware floor for its copy of Nano that the flag does not lift.
  `flutter_edge_ai_builtin_ai` states it as **~22 GB of free disk and a GPU with
  more than 4 GB of VRAM**, or a CPU-only path on a machine with 16 GB of RAM.
  Under it the probe answers `unavailableOther` with the flag
  switched on — which reads like a setup mistake and is not one
* This codelab omits the package's Windows AI Foundry selection, so its app
  deliberately takes the downloaded model on **Windows**. **Linux** is the
  only one of the six platforms with no built-in arm at all. Running either
  fallback exercises that path end to end, as does any supported platform on
  a device whose OS has no model

### Get the code

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/inference-engines-flutter-gemma
ls
```

```text
step_01_starter/           the Getting Started app, unchanged
step_02_two_engines/       after Step 2
step_03_pick_at_startup/   after Step 3
complete/                  after Step 4 — the finished app
```

## Step 1: What an engine is
Duration: 5

### Before you run

The downloaded model in this codelab — the one every fallback path lands on —
is `Models.downloaded`, and on every native platform that is Gemma 3 1B, whose
Hugging Face repository is behind a licence gate. Accept the terms on the
[model page](https://huggingface.co/litert-community/Gemma3-1B-IT) once, create
a read token in your Hugging Face settings, and start every run with it:

```bash
flutter run --dart-define=HF_TOKEN=hf_your_token
```

[Getting Started](/codelabs/getting-started-flutter-gemma) covers that in its
Step 2. Without the token the download 401s — and since a device without a
built-in model takes the fallback path, that is most devices. If you would
rather not have a Hugging Face account, `Models.gemma4` in `model.dart` is
ungated — a 2.59 GB download against Gemma 3 1B's 0.6 GB. The fallback is named in exactly one place — the `Models.downloaded`
getter in `model.dart` — so repoint that one line and every fallback path picks
it up: the startup policy in `main.dart`, the setup screen's **Use … instead**
button in `download_page.dart`, and the chat's switch-model menu.

On the **web** this question does not come up: the browser engine
(`@litert-lm/core`) only runs a `.litertlm` file exported for it, and the
native files install fine and then fail at engine creation. `Models.downloaded` already resolves to `Models.gemma4Web`
there (the same web build [Getting Started](/codelabs/getting-started-flutter-gemma)
uses), so nothing to repoint and no token needed.

### One list of engines

Open `step_01_starter` and run it. It is the Getting Started app: download a
`.litertlm` file, chat with it. Look at one line of `main.dart`:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
  huggingFaceToken: _hfToken.isEmpty ? null : _hfToken,
  webStorageMode: WebStorageMode.streaming,
);
```

`flutter_edge_ai` itself contains **no inference runtime**. It has the install
pipeline, the chat loop, and a registry. Runtimes — engines — come from
separate packages, and each one tells the registry which model files it can
open. `LiteRtLmEngine` opens `.litertlm`. That single list is the only place
the app says which runtimes exist.

When you later call `getActiveModel()`, the registry looks at the active
model's `ModelFileType`, finds an engine whose `canHandle` says yes, and hands
the model to it. Nothing else in your code participates in that choice.

So "switching engines" is not a code path. It is: register a second engine,
and activate a model whose file type routes to it.

## Step 2: Register a second engine
Duration: 18

### Add the package

```bash
flutter pub add flutter_edge_ai_builtin_ai
```

This engine talks to the model the platform already has: Gemini Nano through ML
Kit GenAI on Android and through Chrome's Prompt API on the web, Apple
Foundation Models on iOS and macOS. There is no file. The OS — or the browser —
owns the weights, updates them, and decides whether a given device gets them at
all.

### One platform change

Gemini Nano's Android SDK requires API 26. The package declares that, and the
manifest merger refuses an app that sets less. The app you brought from Getting
Started is already at **30** — LiteRT-LM's own floor, and above this one — so
there is nothing to change here. Leave it where it is:

```kotlin
defaultConfig {
    // …
    // flutter_edge_ai_builtin_ai (ML Kit GenAI / AICore) declares minSdk 26 and
    // the manifest merger rejects an app below it; libLiteRtLm.so needs API 30+
    // Bionic (pthread_cond_clockwait, sem_clockwait) on top of that, so 30 is the
    // floor for an app that registers both engines.
    minSdk = 30
```

If you are adding built-in AI to an app that has *no* LiteRT-LM engine in it,
26 is enough.

iOS needs nothing beyond what Getting Started already set up — the iOS 15.0
deployment target and the three memory entitlements. `flutter_edge_ai_builtin_ai`
declares an iOS 15.0 floor of its own, so a project still pinned at Flutter's
older 13.0 template default has to be raised for this package too; on anything
older than OS 26 every call is gated and simply reports the model as
unavailable.

macOS is iOS's twin here and needs nothing of its own. The **web** needs nothing
in the app either — unlike LiteRT-LM's browser arm there is no script tag to
add, because Chrome's Prompt API is a bare global the browser exposes. What it
needs is the browser to have the feature switched on: the
`chrome://flags/#prompt-api-for-gemini-nano` flag for local development, an
[origin trial](https://developer.chrome.com/origintrials) token for a site you
ship. The package's **Windows** arm delegates to `flutter_local_ai` and Windows
AI Foundry; this codelab does not add that model to its picker, so Windows takes
the downloaded fallback. **Linux** has no OS built-in model at all.

### Register it

```dart
await FlutterEdgeAi.initialize(
  webStorageMode: WebStorageMode.streaming,
  inferenceEngines: [LiteRtLmEngine(), const BuiltInAiEngine()],
  huggingFaceToken: _hfToken.isEmpty ? null : _hfToken,
);
```

Two engines, side by side. Neither knows about the other. `webStorageMode:
WebStorageMode.streaming` matters only on the web: it stores a downloaded
`.litertlm` in OPFS and reads it back as a stream, rather than buffering the
whole file in memory as one Cache API blob. Browsers cap a single blob at
roughly 2 GB — Chrome refuses past it with `ERR_BLOB_OUT_OF_MEMORY` — and the
web model here is 2.0 GB, right on that line. Close enough that every codelab
in this series streams. Native platforms ignore the option entirely.

### Rename these first

If you are editing your own `complete/` from Getting Started rather than
opening `step_02_two_engines`, six names change, and the compiler will find
them in four files:

| Rename | Why | Where it breaks |
|---|---|---|
| `ModelChoice.fileName` → `id` | a built-in model has no file name | `main.dart` gate, `chat_page.dart` `uninstallModel`, `test/widget_test.dart` |
| `ModelChoice.url` → `String?` | a built-in model has no URL | `download_page.dart` needs `.fromNetwork(model.url!)`, and so does the test |
| `ModelChoice.fileType` (new, required) | this is the engine switch | both `Models` constants |
| `DownloadPage.onInstalled` → `onReady` | "installed" is the wrong word for a model the OS owns | `main.dart` gate, the widget test |
| `DownloadPage` gains a required `onSwitch` | the setup screen can fail with nothing left to retry | `main.dart` gate, the widget test |
| `ChatPage` gains a required `onSwitch` | the chat can now ask for a different model | `main.dart` gate |

`download_page.dart` also grows a top-level `activate()` function, below.

### Give the model a shape that fits both

In Getting Started, `ModelChoice` described a file. Now it describes a model
that may or may not *be* a file:

```dart
class ModelChoice {
  // …

  /// How this app names the model. For a downloaded model it is the file name,
  /// which is also what `FlutterEdgeAi.isModelInstalled` is keyed by. For a
  /// built-in one it is the OS model's name — and nothing is keyed by it,
  /// because there is no file and no install record.
  final String id;

  // …

  /// Which engine opens it. `.litertlm` → LiteRtLmEngine, `.builtIn` →
  /// BuiltInAiEngine. This field is the whole "engine switch".
  final ModelFileType fileType;

  /// Where the bytes are. `null` for a built-in model — there is no file.
  final String? url;

  // …

  bool get isBuiltIn => fileType == ModelFileType.builtIn;
}
```

(`// …` is where the constructor and the `label` / `modelType` / `sizeLabel` /
`requiresToken` fields sit — the file has them; this excerpt does not.)

And the built-in model itself, one per platform. It is a getter rather than a
constant only because the platform is decided at run time:

```dart
static ModelChoice get builtIn {
  // `kIsWeb` is asked BEFORE `defaultTargetPlatform`, which on the web
  // reports the host OS — a Chrome on a Mac would otherwise be handed the
  // Apple Foundation Models arm, which only a native app can reach.
  final (spec, label) = kIsWeb
      ? (BuiltInAiModels.geminiNano, 'Gemini Nano (Chrome)')
      : switch (defaultTargetPlatform) {
          TargetPlatform.android => (
            BuiltInAiModels.geminiNano,
            'Gemini Nano',
          ),
          TargetPlatform.iOS || TargetPlatform.macOS => (
            BuiltInAiModels.appleFoundationModels,
            'Apple Foundation Models',
          ),
          _ => throw UnsupportedError(
            'No built-in AI model on $defaultTargetPlatform',
          ),
        };
  return ModelChoice(
    label: label,
    id: spec.name,
    modelType: spec.modelType,
    fileType: ModelFileType.builtIn,
    sizeLabel: 'already on the device',
  );
}
```

Four arms, and the order of the first two is load-bearing. On the web
`defaultTargetPlatform` reports the **host OS**, so a Chrome running on a Mac
answers `TargetPlatform.macOS` — ask it first and the browser is handed the
Apple Foundation Models spec, which only a native app can reach. Asking
`kIsWeb` first is what keeps the browser on Chrome's own Prompt API. The
`geminiNano` spec is the right one there: it carries
`ModelFileType.builtIn`, which is all the registry routes on, and the package's
web arm answers to it.

This codelab's getter omits Windows AI Foundry and Linux has no OS built-in
model, so on both platforms it throws instead of offering a model the sample
did not configure. That is a limitation of this model list, not of
`flutter_edge_ai_builtin_ai`: the package delegates Windows to
`flutter_local_ai`. The chat page's menu builds its list through
`_alternatives`, which asks for `Models.builtIn` inside a `try` and drops the
entry on `UnsupportedError`.
That getter runs from `itemBuilder`, so the guard has to be *in* it: a throw
during a build is a red screen, not something a `catch` around the tap could
reach. The startup probe in Step 3 asks the same getter, but asks it *first*:
where it throws this codelab has no built-in model selected, so the probe never
runs and the app goes straight to Gemma. That is why a Windows or Linux run
quietly downloads it and chats.

### Installed is not active — and a built-in model is never installed

Here is the idea the rest of the codelab rests on, in two halves.

**For a downloaded model.** Installing puts it on the device. Activating makes
it the one `getActiveModel()` loads. The last model you installed is active —
and `install()` is **idempotent**: called on a model that is already there, it
skips the download and just makes it active.

**For a built-in model.** "Installed" is not a concept at all. Nothing is
written to disk and no install record exists, so `FlutterEdgeAi.isModelInstalled`
answers *no* for it forever — before activation and after. Readiness is a
question for the OS, not for your storage.

One function still covers both, because *activating* means the same thing on
either side:

```dart
Future<void> activate(
  ModelChoice model, {
  void Function(int)? onProgress,
}) async {
  if (model.isBuiltIn) {
    // Throws BuiltInAiUnavailableException on a device/OS that has no
    // built-in model, so the failure is typed and the caller can react.
    await BuiltInAi.ensureReady(onProgress: onProgress);
    await FlutterEdgeAi.installModel(
      modelType: model.modelType,
      fileType: model.fileType,
    ).fromBundled(model.id).install();
    return;
  }

  await FlutterEdgeAi.installModel(
        modelType: model.modelType,
        fileType: model.fileType,
      )
      .fromNetwork(model.url!)
      .withProgress((percent) => onProgress?.call(percent))
      .install();
}
```

For the built-in model, `ensureReady()` asks the OS to make its model ready —
on Android the first call may download the feature. Then `install()` records
the identity; there is no file to fetch, so `fromBundled(model.id)` is just a
name.

That OS download is the reason the setup screen's progress bar is
*indeterminate* for a built-in model and determinate for a file: Android
reports a running byte count with `bytesTotal: 0`, and Apple reports nothing at
all, so there is no percentage to draw. A determinate bar pinned at 0% for
minutes reads as a frozen app, which is worse than admitting you do not know.
Chrome is the exception — its Prompt API does report a real percentage — and the
app still draws the indeterminate bar there rather than branch a third way.

The gate from Getting Started therefore grows a branch, not a line — it asks a
different *question* per kind of model:

```dart
Future<bool> _prepare() async {
  if (widget.model.isBuiltIn) {
    // "Installed" is not a concept for a built-in model. The OS owns the
    // weights, nothing lands on disk, and no install record is written — so
    // `isModelInstalled` answers no forever. Ask the OS instead.
    final status = await BuiltInAi.availability();
    if (status != BuiltInAiAvailability.available) return false;
    // Ready, but not yet current: `activate` records the identity that
    // `getActiveModel` will load.
    await activate(widget.model);
    return true;
  }

  final installed = await FlutterEdgeAi.isModelInstalled(widget.model.id);
  // For a downloaded model, installed is still not the same as active.
  // `install()` is idempotent, so re-running it on a model that is already
  // here costs nothing and makes it the one `getActiveModel` will load.
  if (installed) await activate(widget.model);
  return installed;
}
```

Ask the wrong question and the app becomes unreachable rather than broken:
`isModelInstalled` on a built-in model is always false, so the gate would send
you to the setup screen, the setup screen would activate the model
successfully, and the gate would send you straight back. Forever, with no
error anywhere.

### Switch by hand

`step_02_two_engines` adds a menu to the chat's app bar listing the models you
are *not* running — so at most two *Use …* entries, and on iOS the built-in one
reads *Use Apple Foundation Models*. Below them sits *Forget this model*, which
deletes a downloaded one; it is hidden for the built-in model, because there is
no file to free and no record to remove (`uninstallModel` would throw).

Picking a model closes the current runtime and hands the app a different
`ModelChoice`; a new `ValueKey(choice.id)` on the gate restarts it for that
model.

```dart
Future<void> _switchTo(ModelChoice next) async {
  await _inference?.close();
  // Inside `setState`: dropping the chat has to repaint, or the screen keeps
  // showing an enabled composer over a runtime that is gone.
  if (mounted) {
    setState(() {
      _inference = null;
      _chat = null;
    });
    widget.onSwitch(next);
  }
}
```

Close the runtime *before* activating another model. Each engine holds native
memory of its own, and the built-in one holds an OS session. Both menu actions
run through one `_onAction` wrapper that catches whatever they throw, puts it
in the same `_loadError` a failed load uses, and nulls `_chat` alongside it —
closing a runtime and deleting a file are native calls, and a `close()` that
throws has already broken the model while leaving `_chat` non-null, so without
that the page would offer a working composer under *The model did not load.*

Run it. On a device with a built-in model, switch to it and ask the same
question you asked Gemma. A different engine answers, and `_load`, `_send` and
`dispose` are byte-for-byte the code you had — run `diff` over the two
`chat_page.dart` files and every changed line is the app bar's menu, its engine
label, the callback that carries the switch out, or the delete action moving
under that menu: `_removeModel` loses its own `try` (the `_onAction` wrapper
has it now) and takes `model.id` where it took `model.fileName`. Nothing that
talks to the model moved.

On a device *without* one, the switch itself normally succeeds — closing a
runtime is all it does. What happens next is that the gate finds the OS
reporting `unavailable*`, so it shows the setup screen; pressing **Use built-in
model** there is what fails, from `ensureReady()`:

```text
BuiltInAiUnavailableException(BuiltInAiAvailability.unavailableDeviceUnsupported): Built-in AI is not available: BuiltInAiAvailability.unavailableDeviceUnsupported
```

A typed exception carrying a `BuiltInAiAvailability`, not a platform crash —
which is why the setup screen never shows the learner that string. `step_02`'s
error card pattern-matches the status and renders a sentence instead: where the
toggle lives for a disabled feature, that the OS is older than the model
requires, or else the status itself.

Under that sentence sits a **Use … instead** button, its label pulled straight
from `Models.downloaded.label` — **Use Gemma 3 1B instead** on native
platforms, **Use Gemma 4 E2B (web build) instead** in the browser — because a
retry
rarely helps here: only `unavailableDisabled` can change after you flip the
setting it names; for every other status the OS either has a model or it does
not, and pressing **Use built-in model** again reproduces the exception. The
button is why `DownloadPage` takes the gate's `onSwitch` as well as `ChatPage`
— until a model is ready this screen *is* the app, and a screen that names a
way out has to have one. That typed failure is what makes the next step
possible.

## Step 3: Let the app choose
Duration: 8

Which engine a device has is not knowable at build time. A Pixel 9 has Gemini
Nano; a Pixel 7 does not; an iPhone 15 Pro has Apple Foundation Models only
once the user turns Apple Intelligence on. So the app asks, every launch:

```dart
Future<void> _pickAtStartup() async {
  // First: does this platform have a built-in arm at all? `Models.builtIn`
  // throws where it does not, so asking it is the cheap way to find out —
  // and where it throws this codelab has nothing to probe. The sample omits
  // the package's Windows AI Foundry spec; Linux has no OS built-in model.
  // Skip the probe and use the downloaded model.
  final ModelChoice builtIn;
  try {
    builtIn = Models.builtIn;
  } on UnsupportedError {
    if (mounted) setState(() => _choice = Models.downloaded);
    return;
  }

  // Only now, on a platform that does have one: ask the OS. `availability()`
  // never throws for an OS that answers — but a plugin that registered and
  // then broke does, and an uncaught throw here would leave the app on the
  // probe screen forever.
  BuiltInAiAvailability status;
  try {
    status = await BuiltInAi.availability();
  } catch (_) {
    status = BuiltInAiAvailability.unavailableOther;
  }
  final choice = switch (status) {
    BuiltInAiAvailability.available ||
    BuiltInAiAvailability.downloadable ||
    BuiltInAiAvailability.downloading => builtIn,
    _ => Models.downloaded,
  };
  if (mounted) setState(() => _choice = choice);
}
```

Three of the seven statuses mean "the OS can give you a model" — now, after a
download, or once a running download finishes. The other four are the
`unavailable*` family, and for all of them the answer is the same: use the
downloaded model.

Two questions, in that order, and the order is the whole design.

The **first is about the platform**, and it is asked first because it is free:
`Models.builtIn` throws where this app has no built-in arm, so evaluating it
*is* the test. The getter omits Windows from this codelab even though the
package supports Windows AI Foundry through `flutter_local_ai`; Linux is the
only platform here with no OS model. In either case the sample has no built-in
spec to probe, so it returns straight away and takes the downloaded model. This
is the same `on UnsupportedError` the menu uses in Step 2, moved to the front.

The **second is about the plugin**, on a platform that does have an arm: one
that registered and then broke. There a throw is real news, and turning it into
an `unavailableOther` verdict is what keeps the app moving — `_pickAtStartup`
runs unawaited from `initState`, so an escaping throw would leave it stuck on
*Checking for a built-in model…* with the error lost in the zone.

The probe is bounded. On a device whose AI stack never answers (a
freshly-provisioned Android with no AICore metadata yet), `availability()`
gives up after 20 seconds and reports `unavailableOther` rather than hanging
your startup. `step_03_pick_at_startup` shows a *Checking for a built-in
model…* screen for that window.

`downloadable` is the interesting one: the OS *can* have a model but hasn't
fetched the feature yet, so the gate's built-in branch answers "not ready", the
app lands on the setup screen, and pressing the button there runs
`ensureReady()` — with the indeterminate bar from Step 2, because that download
has no total to report.

The manual switch from Step 2 stays in the menu, so you can override the app's
choice and compare. Neither route is one-way. When the probe lands the app on
the built-in setup screen — for `downloadable` as much as for a switch you made
by hand — and `ensureReady()` then fails there, however it fails — a typed
status, or the ten-minute wait on a fetch that never finishes — the error card's
**Use … instead** button hands the app back to the downloaded model. Without it the
only control on that screen would re-run the same failure, and on a
`downloadable` device even a restart would probe the same status and land you
there again.

## Step 4: Say why
Duration: 5

A silent decision is a support ticket waiting to happen: "why is my app
downloading half a gigabyte when the phone has Gemini?" `complete` keeps the
probe's verdict and shows it in a dismissible banner above the chat:

```dart
final ModelChoice builtIn;
try {
  builtIn = Models.builtIn;
} on UnsupportedError {
  if (mounted) {
    setState(() {
      _choice = Models.downloaded;
      _reason =
          'No built-in model on this platform — using a downloaded model.';
    });
  }
  return;
}

// ...

final (choice, reason) = switch (status) {
  BuiltInAiAvailability.available => (
    builtIn,
    'Using the model the OS ships — nothing was downloaded.',
  ),
  BuiltInAiAvailability.downloadable ||
  BuiltInAiAvailability.downloading => (
    builtIn,
    'The OS has a built-in model; it will fetch the feature once.',
  ),
  BuiltInAiAvailability.unavailableDisabled => (
    Models.downloaded,
    'Built-in AI is turned off on this device — using a downloaded model.',
  ),
  _ => (
    Models.downloaded,
    'No built-in model here ($status) — using a downloaded model.',
  ),
};
```

The switch now yields a record, and so does the early return that Step 3's
platform question takes — every path out of the probe, the one that never
reaches the probe included, comes with a sentence the user can read.
`unavailableDisabled` gets its own line because it is the one case the *user*
can fix — the hardware is fine, the feature is switched off.

The sentence and its **Dismiss** live in the same place: `_EnginesAppState`
holds the reason, and the chat page's button calls back into it. Keeping the
dismissal in the chat page's own State would look identical and be wrong — the
gate rebuilds that State whenever the model changes, so forgetting the model
and downloading it again would raise the banner the user had already put down.

That is the finished app. Run `complete` on whatever you have:

* a device with a built-in model → the banner says so, nothing downloads, the
  built-in model answers
* an emulator or an older phone → the banner names the status, Gemma downloads
  once, LiteRT-LM answers
* Windows, which this codelab leaves out of its built-in model picker, or Linux,
  where no OS built-in model exists → the app takes the fallback before probing,
  the banner reads *No built-in model on this platform — using a downloaded
  model*, and Gemma downloads the same way. On Windows this is a sample choice,
  not a package limitation; `flutter_edge_ai_builtin_ai` supports Windows AI
  Foundry through `flutter_local_ai`
* Chrome without the Prompt API flag or origin trial → the same fallback, but
  the model that downloads is `Models.gemma4Web` (2.0 GB, ungated) rather than
  Gemma 3 1B — the browser engine cannot open the native file at all

Same chat page every way.

## What's next
Duration: 2

You now have an app that adapts to the device it lands on. The registry idea
extends further than these two engines:

* **MediaPipe** (`flutter_edge_ai_mediapipe`) opens `.task` files on Android,
  iOS and the web
* **ONNX Runtime** (`flutter_edge_ai_onnx`) opens ONNX model directories on
  macOS, Linux, Windows, Android and iOS, and runs on the web through
  Transformers.js
* **LiteRT-LM** — the engine you already registered — has a **web** arm too,
  running `.litertlm` in the browser through `@litert-lm/core`, which is what
  makes this app's fallback work in Chrome as well. It only runs a `.litertlm`
  file exported for the browser, though — `Models.downloaded` is
  `Models.gemma4Web` there, not `Models.gemma3`, for exactly that reason

Each registers the same way and answers through the same chat code.

### Reference

* [flutter_edge_ai_builtin_ai on pub.dev](https://pub.dev/packages/flutter_edge_ai_builtin_ai)
  — supported devices, OS floors, and what each availability status means
* [Built-in AI documentation](/docs/builtin-ai)
* [Source and this codelab's code](https://github.com/DenisovAV/flutter_edge_ai)
