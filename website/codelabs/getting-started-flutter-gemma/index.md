author: Sasha Denisov
summary: Getting Started with On-Device LLMs in Flutter
id: getting-started-flutter-gemma
categories: flutter, ai, gemma
environments: android, ios, macos, windows, linux, web
status: Published

# Getting Started with On-Device LLMs in Flutter

## Overview
Duration: 3

### What you'll build

A small Flutter chat app that downloads a language model once, then answers
questions with the network switched off. No API key, no server, no per-token
bill — the weights sit on the device and the tokens are generated there.

By the end you will have an app that:

* downloads a model file with a progress bar, and knows on the next launch
  that it already has it
* opens a chat session against that model
* streams the reply token by token, the way a chat app should
* says what went wrong when something does, instead of freezing
* cleans up after itself — both the native runtime and the half-gigabyte file

### What you'll learn

The mechanics are only a few dozen lines. What takes the time is the handful
of decisions the API asks you to make, and this codelab is built around them:

* why `flutter_edge_ai` refuses to run until you hand it an **engine**
* how a model's **file type** decides which runtime opens it
* why `maxTokens` is not the reply length, and what to use instead
* why the model's **file name is its id**, and what breaks when you forget

### What you'll need

* Flutter 3.44 or newer
* Any one of Flutter's six platforms: an arm64 Android device or emulator (an
  Apple-silicon Mac's emulator is arm64), an iOS device or simulator, an
  Apple-silicon Mac, a Windows or Linux desktop, or Chrome. The same code runs
  on all of them — Step 2 lists the handful of things each one asks of you, and
  which model it downloads there
* Free space and a connection that can pull it: about 1 GB on native for
  Gemma 3 1B (0.6 GB), or about 3 GB if you take the no-account path, Gemma 4
  E2B (2.59 GB). About 3 GB on the web too, where the app downloads a
  different model — 2.0 GB, and a browser
  that is nearly out of storage refuses a write rather than slowing down, so
  leave it headroom (Step 2 explains why the web model is a different one)
* Optionally, a free Hugging Face account (Step 2 explains when you need one —
  not on the web)

### Get the code

Every step of this codelab exists as a complete, runnable app, so you can
join at any point or check your work against the next one.

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/getting-started-flutter-gemma
ls
```

```text
step_01_starter/     the shell you start from
step_02_download/    after Step 2
step_03_chat/        after Step 3
step_04_streaming/   after Step 4
complete/            after Step 5 — the finished app
```

## Step 1: The starter app
Duration: 3

Open `step_01_starter` and run it.

```bash
cd step_01_starter
flutter run
```

You get a chat screen with the composer disabled and a line saying there is no
model yet. That is the whole app — one file, no plugin, nothing to configure:

```dart
class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    // ... a disabled TextField and a send button that does nothing
  }
}
```

Starting from a plain Flutter app is deliberate. Everything that follows is an
addition you can see, and if something breaks you know which addition did it.

## Step 2: Add the plugin and download a model
Duration: 12

This is the longest step, and the only one with platform configuration in it.

### Add the two packages

```bash
flutter pub add flutter_edge_ai flutter_edge_ai_litertlm
```

Two packages, not one, and the reason matters.

`flutter_edge_ai` is the **core**: the install and runtime API, the chat loop,
the registry. It ships no inference runtime at all. `flutter_edge_ai_litertlm`
is one such runtime — the LiteRT-LM engine, which reads `.litertlm` files on
Android, iOS, desktop and the web. There are others (MediaPipe for `.task`, ONNX
Runtime, the OS built-in models), and you take only the one you need, because
each drags in native binaries you would otherwise ship for nothing.

On the web, "reads `.litertlm` files" comes with a catch this codelab's model
choice is built around: the browser engine (`@litert-lm/core`) only runs a
`.litertlm` file **exported for it**. The native files this codelab uses
elsewhere install on web and then fail the moment the engine starts. The "Choose a model" section below
says which one does exist and why `main.dart` reaches for it only on that one
platform.

### Configure the platforms

Less than you would expect on any of the six, and nothing at all on two of them.
Read the subsection for the platform you are running on and skip the others.

**Android** — two things. First, the internet permission, because downloading
the model is an ordinary HTTPS request:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
```

Second, the API floor, in `android/app/build.gradle.kts`:

```kotlin
defaultConfig {
    // …
    // libLiteRtLm.so needs API 30+ Bionic (pthread_cond_clockwait,
    // sem_clockwait). Below 30 the app installs and then fails at the first
    // model load with a dlopen error.
    minSdk = 30
```

This one is easy to miss, because nothing rejects the build: Flutter's template
floor (24) merges fine, the APK installs, and the failure arrives later as a
`dlopen` error the first time you load a model. The step apps are already at 30.

You do **not** need to declare the OpenCL libraries the GPU backend uses. The
plugin's own manifest declares them and the manifest merger folds them into
your app.

**iOS** — two things. First, the deployment target: the plugin's podspec
declares iOS **15.0**, and CocoaPods refuses to install a pod whose floor is
above your app's. The step apps are already at 15.0, and Flutter's own app
template has defaulted to 15.0 since Flutter 3.47 — but a project created on
anything older is pinned at 13.0, and `pod install` will say so. If you are
adding this to your own app, set `IPHONEOS_DEPLOYMENT_TARGET` to 15.0 in
`ios/Runner.xcodeproj/project.pbxproj` (Xcode → Runner → General → **Minimum
Deployments** writes it for you), and `platform :ios, '15.0'` in `ios/Podfile`
if your project has one.

Second, three memory entitlements, in `ios/Runner/Runner.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.kernel.extended-virtual-addressing</key>
	<true/>
	<key>com.apple.developer.kernel.increased-memory-limit</key>
	<true/>
	<key>com.apple.developer.kernel.increased-debugging-memory-limit</key>
	<true/>
</dict>
</plist>
```

…and point the Runner target at it, which is what Xcode's **Signing &
Capabilities** editor writes for you (`CODE_SIGN_ENTITLEMENTS =
Runner/Runner.entitlements;` in each of the target's Debug, Release and Profile
configurations). The step apps from Step 2 onwards already carry all three keys.

These lift the per-process memory ceiling iOS imposes. Half a gigabyte of
weights plus a KV cache is comfortably over the default jetsam limit on an
older iPhone, and the kill that follows has no Dart-visible error — the app
simply disappears. The third key is the second one's debug twin: it is the one
that applies while a debugger is attached, which is every `flutter run` this
codelab asks you to do, so leaving it out costs you exactly the runs you are
about to make.

**macOS** — two entitlements and one build phase. The entitlements go in
**both** `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`, beside the keys `flutter create` already
wrote there:

```xml
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
```

`network.client` is what lets a sandboxed macOS app reach Hugging Face at all.
`disable-library-validation` does nothing yet: it matters once Hardened Runtime
is on, which notarizing the app for distribution requires. The build phase below
signs LiteRT-LM and its companion libraries ad hoc, and library validation
refuses code not signed by Apple or by your own team. The iOS keys above are
deliberately **not** here: they are iOS entitlements. On macOS a build with no
signing team fails outright with `"Runner" has entitlements that require signing
with a development certificate`, and a team-signed build silently drops them — a
model this size does not need them. macOS support is Apple Silicon only.

The build phase is the part unique to macOS. Every step app from this one on
ships a `macos/Podfile`, and its `post_install` block stages the runtime's
companion libraries into the built `.app` and repoints LiteRT-LM at them. It is
not cosmetic, and how it bites depends on how much of the staging is missing.
With a Podfile that installs pods but carries no such block, LiteRT-LM itself
loads and only its Metal companion is absent: `engine_create` returns null on
the GPU backend and the model silently falls back to CPU. With nothing staged at
all — the SPM case below — `LiteRtLm.framework` is the only thing in
`Contents/Frameworks`, the dynamic loader cannot resolve the companions it
links against, and the first model load fails outright. Copy the block from any
step app's `macos/Podfile` — or
from the [desktop docs](/docs/desktop), which quote it in full with the
reasoning for each line — and run `pod install`.

One trap, measured on these very apps. With Swift Package Manager enabled
(`flutter config --enable-swift-package-manager`) and no other CocoaPods plugin
in the app, Flutter resolves every plugin through SPM and prints **Removing
CocoaPods integration** — which is exactly what it does. The Podfile stops being
part of the build, the `post_install` block never runs, nothing is staged, and
the model fails to load with nothing in the error mentioning CocoaPods. A macOS
build that succeeds proves nothing here: the app compiles, links, signs and
launches either way, and the failure —
`Failed to load dynamic library 'LiteRtLm.framework/LiteRtLm'` — arrives at the
first model load, which no build log will ever warn you about. For this project,
either turn SPM off with `flutter config --no-enable-swift-package-manager`, or
keep one CocoaPods plugin in the app.

**Windows** — nothing in the app, and x86_64 only: there is no Windows arm64
build of the runtime, so a Snapdragon-X machine is out. Nothing needs installing:
nothing in the bundle needs a C++ runtime the machine does not already have.

**Linux** — nothing in the app either. glibc 2.34 or newer, which means Ubuntu
22.04+, Debian 12+ or RHEL 9+. Building a Flutter Linux app at all also wants
`clang cmake ninja-build libgtk-3-dev lld`, and `flutter doctor` names whichever
of those you are missing. The GPU backend reaches Vulkan through Dawn, so it
wants a working vendor driver: Mesa's `llvmpipe` software fallback caps
`maxStorageBufferRange` at 128 MB, and the [desktop docs](/docs/desktop) list
both the driver packages and which models that cap rules out.

**Web** — three script tags, two of them copied out of the plugin. The browser
arm loads the runtime from a CDN, and that ES module assigns no window globals —
module scripts are deferred, so Dart would reach the engine before the
constructor exists. `web/index.html` publishes a promise instead, and Dart
awaits it. Every step app from this one on carries it in `<head>`, followed by
the two scripts the plugin's own web storage needs:

```html
<script type="module">
window.litertLmReady = (async () => {
  const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.17.1/+esm');
  window.Engine = m.Engine;
  return m.Engine;
})();
</script>

  <!-- Cache API + OPFS helper: FlutterEdgeAi.initialize's
       webStorageMode: WebStorageMode.streaming needs both to install
       .litertlm models on web. Copied verbatim from flutter_edge_ai's own web/. -->
  <script src="cache_api.js"></script>
  <script src="opfs_helper.js"></script>
```

`cache_api.js` and `opfs_helper.js` are not a pub.dev asset — copy them out of
the `flutter_edge_ai` package pub already resolved on your machine. Find where
that is:

```bash
grep -A1 '"name": "flutter_edge_ai"' .dart_tool/package_config.json
```

...and copy the two files out of `web/` at that path into your own app's
`web/`, next to `index.html`.

The last piece is one argument on `FlutterEdgeAi.initialize`, back in
`main.dart`:

```dart
webStorageMode: WebStorageMode.streaming,
```

With `streaming`, a `.litertlm` install on the web goes through OPFS (Origin
Private File System) and is read back as a stream. The default `cacheApi` mode
instead buffers the whole download in memory as one blob, and browsers cap a
single blob at roughly 2 GB — Chrome refuses past it with
`ERR_BLOB_OUT_OF_MEMORY`. The web model below is 2.0 GB, right on that line.
Close enough that every codelab in this series uses `streaming` rather than
find out, browser by browser, where the real limit sits.

The web arm is an early preview: WebGPU, and text only — no images, no audio.
The model is not a file on disk there — the browser writes it into OPFS, so
"installed" means "in this browser's storage, on this machine". The bytes stay
in OPFS across a reload; the app's handle on them does not. The `opfs://`
mapping lives in memory and only the download registers it, so after a reload
the install record still reads "installed" and the download screen is skipped,
while the engine is handed the original download URL and fetches the whole
model again. Keep the tab open while you work: a reload costs you another 2 GB
over the network, not another 2 GB on disk.

One more thing is web-specific, and it is not a preview limitation — it is a
different model. Verified against the published packages: install and open
`Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm` (Step 3's Gemma 3 1B) in
a browser, and it downloads fine, then fails the moment the engine starts:

```text
Error: Streaming kTfLitePrefillDecode models is not supported yet.
```

That is `@litert-lm/core` refusing a file it was never built for — it is a
native export, and the browser engine only runs a `.litertlm` file
**exported for the web**. Gemma 3 1B has none published.
[Gemma 4 E2B](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)
does — `gemma-4-E2B-it-web.litertlm`, 2.0 GB, and ungated, so no Hugging Face
token either — and it is what this codelab's apps download on web instead.
"Same code, different platform" still holds: `main.dart` picks the model with
one `kIsWeb` check, and every line after that — install, chat, streaming — is
the code you are about to write for Gemma 3 1B, unmodified.

### Register the engine

Engines are fully opt-in. The core registers none, so an app that never says
which runtime it wants gets a `StateError` the first time it calls
`getActiveModel()`, telling it to add an engine package. (Installing a model
works without one — nothing has to open the file to write it.) Wire it up in
`main`:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Engines are fully opt-in: the core package registers none by itself.
  // Without LiteRtLmEngine here, the first model call throws a StateError
  // that tells you to add an engine package.
  await FlutterEdgeAi.initialize(
    inferenceEngines: [LiteRtLmEngine()],
    huggingFaceToken: _hfToken.isEmpty ? null : _hfToken,
    // OPFS streaming. On web the model is 2.0 GB, right on the ~2 GB blob
    // ceiling the default `cacheApi` mode would have to buffer it into.
    // The other platforms ignore this option.
    webStorageMode: WebStorageMode.streaming,
  );

  runApp(const QuickstartApp());
}
```

### Choose a model

Put the model's identity in one place. The file name is not decoration — it is
the id the plugin installs under and the id you ask about later:

```dart
abstract final class Models {
  static const gemma3 = ModelChoice(
    label: 'Gemma 3 1B',
    url:
        'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/'
        'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    fileName: 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    modelType: ModelType.gemmaIt,
    sizeLabel: '0.6 GB',
    requiresToken: true,
  );

  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    fileName: 'gemma-4-E2B-it.litertlm',
    modelType: ModelType.gemma4,
    sizeLabel: '2.59 GB',
    requiresToken: false,
  );

  // The web build — see "Configure the platforms" → Web, above, for why this
  // one exists and the other two do not run in a browser.
  static const gemma4Web = ModelChoice(
    label: 'Gemma 4 E2B (web build)',
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    fileName: 'gemma-4-E2B-it-web.litertlm',
    modelType: ModelType.gemma4,
    sizeLabel: '2.0 GB',
    requiresToken: false,
  );
}
```

Which one the app actually runs is one line in `main.dart`:

```dart
const _model = kIsWeb ? Models.gemma4Web : Models.gemma3;
```

Gemma's repository is behind a licence gate: open the
[model page](https://huggingface.co/litert-community/Gemma3-1B-IT), accept the
terms once, then create a read token in your Hugging Face settings and pass it
at run time:

```bash
flutter run --dart-define=HF_TOKEN=hf_your_token
```

**No Hugging Face account?** On native platforms, switch the `_model`
constant's non-web arm to `Models.gemma4`. That repository is ungated, so it
downloads with no token at all, and every other line of this codelab stays the
same. It is a bigger download — 2.59 GB against 0.6 GB — and on a phone it
wants 6 GB of RAM or more. On the web the app already needs no token — `_model`
picks `gemma4Web` for you, and that repository is ungated as well.

A token belongs on the command line, never in source control. `String.fromEnvironment` reads it at compile time and the value never enters a file you might commit. The plugin attaches it only to URLs whose host contains `huggingface.co`, so a token set once does not ride along to the other hosts your app downloads from. (That test is a substring match, so treat it as a convenience rather than a security boundary.)

### Download it

```dart
await FlutterEdgeAi.installModel(
      modelType: widget.model.modelType,
      fileType: ModelFileType.litertlm,
    )
    .fromNetwork(widget.model.url)
    .withProgress((percent) {
      if (mounted) setState(() => _percent = percent);
    })
    .install();
```

The two arguments to `installModel` answer different questions. `fileType`
says **which runtime reads the file**, and it is the line people forget: it
defaults to `task`, which routes to MediaPipe. `modelType` says **what the
model is** — but for a `.litertlm` file it does *not* choose the chat
template: the LiteRT-LM engine applies the file's own baked-in template on
every platform, so your message goes in raw either way. What `modelType`
drives instead is model-specific handling downstream — which format the
plugin parses a model's tool calls with, and per-model quirks such as
Qwen3's `/no_think` suffix and its thinking-tag stripping.

It is not about where the bytes land — they land in the same place either way.
`fileType` is what the registry matches engines against: it asks each
registered engine's `canHandle` about the file type the model was *declared*
with, and `LiteRtLmEngine` answers yes only to `.litertlm`. So a `.litertlm`
model installed under the `task` default would be offered to MediaPipe — which
this app never registered, so nothing claims the type at all. The download
still succeeds, and the failure arrives later, out of `getActiveModel()`, as
the same `StateError` you get for a missing engine package: *No inference
engine can handle this model (ModelFileType.task).*

`withProgress` reports whole percent, 0 to 100.

### When the download fails

On a gated model the likeliest failure of this whole codelab is the licence,
and it arrives **typed**: the plugin wraps a failed download in a
`DownloadException` around a sealed `DownloadError`, so `download_page.dart`
matches on the type rather than sniffing the message for "401":

```dart
final (title, body) = switch (error) {
  DownloadException(error: UnauthorizedError() || ForbiddenError())
      when requiresToken =>
    (
      'Hugging Face refused the download',
      'Accept the model licence on its Hugging Face page, then run with '
          '--dart-define=HF_TOKEN=hf_your_token.',
    ),
  DownloadException(:final error) => (
    'Download failed',
    error.toUserMessage(),
  ),
  _ => ('Download failed', '$error'),
};
```

A 401 and a 403 mean the same thing here — the licence is not accepted, or no
token was passed — and `_ErrorCard` says exactly that instead of putting an
exception on screen. Everything else falls through to `toUserMessage()`, which
the plugin writes per `DownloadError`.

Run it. You should watch the bar fill and land on the placeholder screen.
Compare against `step_02_download` if it doesn't.

Which screen you land on is not luck: `main.dart` asks
`FlutterEdgeAi.isModelInstalled` before it decides what to show. That gate is
already doing its job — Step 5 comes back to it, because that one question is
the difference between an app that opens on the chat and one that can never get
past the download screen.

## Step 3: Your first reply
Duration: 7

Two objects stand between you and an answer.

```dart
final inference = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
// ... hand `inference` to the State here, before anything else can throw
final chat = await inference.createChat(
  modelType: widget.model.modelType,
  maxOutputTokens: 256,
);
```

`getActiveModel` loads the installed weights into a runtime. `createChat` opens
a conversation on top, and it is the chat that remembers what was said.

The elided line is not bookkeeping. `_load` assigns `_inference` the moment
`getActiveModel` returns, because everything after that can throw and a runtime
the page never stored is a runtime `dispose` can never close. And if the page
was already disposed by the time the model opened, `_load` closes it on the
spot — there is nobody left to do it later.

**`maxTokens` is the context window**, not a cap on the answer's length — the
prompt, the history and the reply all share it. Ask for 100 hoping for a short
reply and you do not get a short reply: on Android, iOS and desktop the
LiteRT-LM engine raises the value back to 1024 — the smallest context a
`.litertlm` model's baked KV cache can be built for — and logs that it did.
LiteRT-LM's *web* arm does not use `maxTokens` at all, so there is no
correction and no log there. (MediaPipe's web engine does pass it on, for what
that is worth here: this app never registers MediaPipe.) Either way it is not a
length cap, so use `maxOutputTokens` on the chat, as above, and leave
`maxTokens` big enough for prompt + history + reply.

Sending a message is two calls — add it, then ask:

```dart
await chat.addQueryChunk(Message.text(text: text, isUser: true));
final response = await chat.generateChatResponse();
```

**`Message` defaults `isUser` to `false`.** Leave it out and you have appended
something the model reads as its own previous turn — the reply comes back empty
or bizarre, with no error anywhere.

The result is a sealed `ModelResponse`, because a model can answer with plain
text, with a tool call, or with its own thinking. With no tools declared this
call only ever hands back the text arm, so one `switch` covers it and leaves
the door open for later:

```dart
_turns.add(
  _Turn(switch (response) {
    TextResponse(:final token) => token,
    _ => '(unsupported response)',
  }, fromUser: false),
);
```

### When it fails

This is the first code that talks to the *inference* runtime, so it fails in
ways the download screen never saw: a forgotten engine package, too little
memory to open the weights, a half-written model file. Both entry points get a
`catch` — and `_send` gets a `finally`:

```dart
} catch (error) {
  if (mounted) setState(() => _loadError = error);
}
```

```dart
} catch (error) {
  // The chat's own history now holds a user turn the model never answered;
  // a production app would reset it with `clearHistory`.
  if (mounted) {
    setState(() => _turns.add(_Turn('⚠️ $error', fromUser: false)));
  }
} finally {
  // `_busy` is what disables the composer, so clearing it belongs in
  // `finally` — a failed generation must not lock the app.
  if (mounted) setState(() => _busy = false);
}
```

The `finally` is the part that matters. `_busy` is what greys out the text
field and the send button, and it is set *before* the call. Clear it only on
the success path and one failed generation disables the composer for the life
of the screen — the app looks alive and accepts nothing, and there is no error
on screen to explain it. Anything that can throw between "disable the UI" and
"enable it again" belongs in a `try`, with the re-enable in `finally`.

`_load`'s failure gets a message and a **Try again** button in place of the
loading bar, because "the model would not open" is a state the user can act on.

One honest limitation, noted in the `catch`: `addQueryChunk` commits your
message to the chat's history before generation runs, so a failed turn leaves a
user message the model never answered — in the Dart-side history and in the
native session both. The chat still works; every later turn is just asked of a
transcript with a hole in it. An app that cares would call
`chat.clearHistory(replayHistory: …)` there. This one keeps the screen simple.

Finally, close what you opened. The runtime holds native memory that Dart's
garbage collector knows nothing about:

```dart
@override
void dispose() {
  _inference?.close().catchError((Object _) {});
  _input.dispose();
  super.dispose();
}
```

`dispose` cannot `await`, so the future is dropped deliberately — and caught,
because an unawaited throw from a native teardown surfaces as an unhandled
async error with no useful stack.

All of this lives in a new `chat_page.dart`, and one line of `main.dart` puts
it on screen: the gate returns the chat where Step 2 returned the placeholder.
Add `import 'chat_page.dart';`, change that line, and delete the `_ModelReady`
class it replaces.

```dart
if (snapshot.data ?? false) {
  return ChatPage(model: widget.model);
}
```

Run it and ask something. The app freezes for a few seconds, then the whole
answer appears at once. That pause is the next step.

## Step 4: Stream the reply
Duration: 4

The model produces the answer one piece at a time; waiting for all of it before
drawing anything throws that away. Swap one call for its streaming twin:

```dart
final buffer = StringBuffer();
await for (final chunk in chat.generateChatResponseAsync()) {
  if (chunk is TextResponse) {
    buffer.write(chunk.token);
    if (!mounted) return;
    setState(
      () => _turns[_turns.length - 1] = _Turn(
        buffer.toString(),
        fromUser: false,
      ),
    );
  }
}
```

**Each `TextResponse` carries only the new text**, not the reply so far. Assign
it instead of appending and you render only the last fragment — a bug that
looks like the model emitting a single word.

The `if (!mounted) return;` is not decoration either: generation outlives the
screen if the user backs out mid-reply, and `setState` on a disposed `State`
throws. The `finally` from Step 3 still runs on that early return, and skips
its own `setState` for the same reason.

Add the empty assistant turn *before* the loop starts, so there is something
on screen for the tokens to flow into — and change the `catch` to replace that
last turn rather than append a new one, or a failed reply leaves the empty
bubble behind, sitting above the error.

Run it again. Same model, same answer, and the app now feels like it is
thinking out loud instead of hanging.

## Step 5: Install once, not every launch
Duration: 4

The gate that decides whether the app opens on the chat or on the download
screen has been there since Step 2 — one question, asked before deciding what
to show:

```dart
Future<bool> _check() => FlutterEdgeAi.isModelInstalled(widget.model.fileName);
```

What `complete` adds is a delete button, so you can make that question answer
"no" again on demand — plus the one gate line that lets the button send you
back. This step is where the rest of the story around `_check()` gets told —
why the id has to be exactly right, and what does and does not survive a
restart.

That one line is why the file name lives in a constant. `isModelInstalled` is
keyed by the name the model was installed under, and the plugin derives that
name from the last segment of the URL — which is why the `fileName` in `Models`
is exactly that segment. One typo apart and the check is answering about a file
that was never written.

What that costs you is not bandwidth. `install()` is idempotent: it looks up
the name it is about to write, sees the model already there, logs *skipping
download* and returns in milliseconds. So the bytes are still fetched exactly
once — what breaks is the gate. It answers "no" forever, so the app opens on
the download screen every launch, the "download" finishes instantly, the gate
is asked again, still answers "no", and you land straight back on the download
screen. Unreachable rather than broken, with no error anywhere.

Every step directory has carried a test for that since Step 2, because it is
the kind of mistake that is invisible when it is wrong:

```dart
test('every model id matches the last segment of its URL', () {
  for (final model in [Models.gemma3, Models.gemma4, Models.gemma4Web]) {
    expect(model.fileName, model.url.split('/').last, reason: model.label);
  }
});
```

**What survives a cold start is the decision, not the bytes.** Kill the app
mid-download and relaunch: the gate asks again, sees no installed model, and
starts over from zero. That is deliberate. Hugging Face serves *weak* ETags, so
the plugin sets `allowPause: false` for `huggingface.co` URLs — byte-range
resume against a server that cannot promise the range still matches is worse
than a clean restart. A model hosted on GCS, Firebase Storage, Kaggle or your
own server does resume. It is worth knowing which of those you are on before
you promise your users a resumable download.

The corollary bites on Android: because a Hugging Face transfer cannot pause,
one that runs past WorkManager's nine-minute execution cap fails outright
instead of pausing and re-enqueuing. On a slow connection a 0.6 GB model can
hit that, and the fix is a faster network or a host that supports resume — not
a retry loop.

To watch the whole cycle, `complete` adds a delete button. `ChatPage` gains a
required `onModelRemoved` callback to carry the news back, and the gate
supplies it where it already builds the chat:
`onModelRemoved: () => setState(() => _installed = _check())` — the same
one-line re-ask `onInstalled` has used since Step 2. The button's handler:

```dart
Future<void> _removeModel() async {
  try {
    await _inference?.close();
    // Inside `setState`: dropping the chat has to repaint, or the screen
    // keeps showing an enabled composer over a runtime that is gone.
    if (mounted) {
      setState(() {
        _inference = null;
        _chat = null;
      });
    }
    await FlutterEdgeAi.uninstallModel(widget.model.fileName);
    if (mounted) widget.onModelRemoved();
  } catch (error) {
    // Deleting can fail too — a missing install record, a file the OS still
    // holds. Show it the way a failed load is shown, and drop the chat with
    // it: a `close()` that threw leaves `_chat` non-null, and "The model did
    // not load." over a working composer is a lie.
    if (mounted) {
      setState(() {
        _chat = null;
        _loadError = error;
      });
    }
  }
}
```

Close the runtime *before* deleting the file. The weights are memory-mapped
while a model is open, and pulling the file out from under the engine is a
crash waiting to happen. For the same reason the button is disabled while the
model is still opening — the runtime may not exist yet, and `getActiveModel` is
holding the file open behind the progress bar.

The `try` and the `setState` are the same lesson as Step 3, one screen over.
`uninstallModel` throws if the install record is already gone, and without the
`catch` that exception escapes into the zone: `onModelRemoved` never fires, the
gate never re-runs, and the screen is left on a progress bar that never
resolves — `_chat` was nulled two lines earlier, so the composer is already
disabled and nothing on screen says why. The enabled composer belongs to the
*other* throw: `close()` fails before the success path drops `_chat`, which is
why the `catch` nulls it as well — without that line the screen would say "The
model did not load." over a composer that still answers. Nulling the fields
outside `setState` gets you the same painted lie more cheaply.

Delete it, and the gate flips back to the download screen on the next check —
which is the cheapest way to test the gate itself.

## What's next
Duration: 2

You have an app that runs a language model with the network off. The same
core API is the entry point to everything else the plugin does:

* **let your coding assistant write the next feature** — `flutter_edge_ai` ships
  skills your assistant reads; the
  [Package Skills codelab](/codelabs/package-skills-flutter-gemma) installs
  them and shows how to check what it writes
* **swap the model** — change one constant; `.litertlm` files from
  [litert-community](https://huggingface.co/litert-community) all work the same
  way on native platforms — on the web, only a file exported for the browser
  engine does
* **run a different engine** — the OS built-in model (Gemini Nano, Apple
  Foundation Models) needs no download at all:
  [Inference Engines](/codelabs/inference-engines-flutter-gemma)
* **send images and audio** — `Message.withImages` / `Message.withAudio`, on
  models that accept them: [Multimodal Inference](/codelabs/multimodal-flutter-gemma)
* **let the model call your Dart functions** — tools and the call/response loop:
  [Function Calling](/codelabs/function-calling-flutter-gemma)
* **ground answers in your own documents** — embeddings and on-device vector
  search: [On-Device RAG](/codelabs/on-device-rag-flutter-gemma)
* **run it as a voice loop** — speech-to-text in, text-to-speech out:
  [Voice Assistant](/codelabs/voice-assistant-flutter-gemma)
* **route between the cloud and the device** — Gemini and the on-device model
  behind one Genkit call: [Hybrid AI with Genkit](/codelabs/hybrid-ai-flutter-genkit)

Every one of those codelabs is published; the [catalogue](/codelabs) lists
them all.

### Reference

* [flutter_edge_ai on pub.dev](https://pub.dev/packages/flutter_edge_ai)
* [Documentation](/docs/getting-started)
* [Source and this codelab's code](https://github.com/DenisovAV/flutter_edge_ai)
