author: Sasha Denisov
summary: Multimodal Inference in Flutter — Vision and Audio on Device
id: multimodal-flutter-gemma
categories: flutter, ai, gemma, multimodal
environments: android, ios, macos, windows, linux, web
status: Published

# Multimodal Inference in Flutter: Vision and Audio on Device

## Overview
Duration: 3

### What you'll build

The chat app from the *Getting Started* codelab, taught to send a **picture**
and a **recording** to the model — and, at the end, taught to know where it
cannot.

Two models, and the second one is the point. Step 2 starts on **SmolVLM2
500M**: 0.36 GB, about a minute of download, and the app is describing your
own photograph. Step 3 wants audio — and no flag switches on an encoder the
weights do not contain, so it moves to **Gemma 4 E2B**, 2.59 GB. Seven times
the size, said plainly rather than in a footnote. (That is the native journey.
On the web, SmolVLM2 has no browser build at all, so Step 2 is already Gemma 4
E2B there — Step 2's own section explains why, and Step 3 changes nothing
further on that platform.)

You pay it once. Those weights read pictures *and* hear you, so the app never
ends up juggling one model per modality: `complete` ships exactly one.

That is the idea worth taking away:

**A modality is a flag, not a model identity.** Inside a checkpoint that has
the encoder, you do not swap models to add vision or audio. You open the same
weights with another capability switched on — `supportImage`, `supportAudio` —
and the rest of your chat code does not move.

The flag goes in **two** places, and this is the trap: on `getActiveModel`,
where the engine is built and decides whether to load a vision or audio
executor, *and* on `createChat`, where the session declares what it will send.
Set it only on the chat and nothing complains — the model downloads, the engine
starts, the UI offers you the camera — until the first picture, when native
fails the turn with `INVALID_ARGUMENT: Vision executor should not be null`.
A setup mistake that surfaces as a generation error, minutes and a whole model
download after you made it.

Which turns the interesting question around. It stops being *"which model do I
need?"* and becomes *"what does this platform let me switch on?"* — because
that answer is not yours to set. The web runtime has no vision or audio
executor at all, and it says so late: the chat opens with both flags set, and
the refusal comes as an `UnsupportedError` when the picture is sent — after
the user has already picked it. Step 4 is about asking first, and about saying
which side said no — a model that cannot, or a platform that will not. Two
different failures with two different fixes, and this codelab hands you one of
each.

### What you'll learn

* how to attach an image with `Message.withImages` and a clip with
  `Message.withAudio`
* what `supportImage` / `supportAudio` on `createChat` actually switch on, and
  why the same flag has to go on `getActiveModel` as well
* what a second modality costs when the weights do not have it, and why one
  checkpoint carrying both beats two that carry one each
* how to capture 16 kHz mono audio without a file, and why that matters for
  the web build
* that capability is **not** a build-time constant — the app has to ask what
  this platform allows, and name it when the answer is no
* what a learner on the web or an iOS Simulator should expect instead of a
  crash

### What you'll need

* The finished app from
  [Getting Started with On-Device LLMs in Flutter](/codelabs/getting-started-flutter-gemma)
  — or just its `complete/` directory, which is this codelab's starter
* **No Hugging Face token** from Step 2 on: both repositories this codelab
  introduces are ungated, so every `flutter run` from there is a plain
  `flutter run` with no `--dart-define`. Step 1 is Getting Started's finished
  app unchanged, and it still runs that codelab's gated Gemma 3 1B, which needs
  `--dart-define=HF_TOKEN=hf_...`
* Room for **0.36 GB** in Step 2 on native, and for **2.59 GB** from Step 3 on
  — plus the memory to open the larger one, roughly 6 GB of RAM. A 4 GB phone
  is killed by the OS rather than told no. On the **web**, Step 2 already
  needs Gemma 4 E2B's **2.0 GB** web build (SmolVLM2 has none), so leave about
  3 GB free for it per step you run in the browser — a browser close to its
  storage quota refuses the write rather than slowing down. Step 3 uses the
  same file, but each step app downloads it again on the web; Step 3 says why
* Android (an **arm64** device or emulator — `flutter_edge_ai_litertlm` ships an
  arm64 library and nothing else, so a 32-bit or x86_64 image has no runtime to
  load), a real iPhone or iPad, macOS, Windows or Linux for the full thing.
  The web and the iOS Simulator both run this app; Step 4 covers what they do
  instead

### Get the code

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/multimodal-flutter-gemma
ls
```

```text
step_01_starter/     the Getting Started app, unchanged
step_02_vision/      after Step 2 — a small vision model, and it can see
step_03_audio/       after Step 3 — a bigger one, and it hears too
complete/            after Step 4 — and it knows where it cannot
```

## Step 1: A modality is a session flag
Duration: 4

### Run the starter

Open `step_01_starter` and run it. It is the Getting Started app: download a
`.litertlm` file, chat with it, in text.

Now look at the call that opens the chat, because that is where this codelab's
central change lands:

```dart
      final chat = await inference.createChat(
        modelType: widget.model.modelType,
        maxOutputTokens: 256,
      );
```

### One checkpoint, several sessions

`createChat` takes `supportImage` and `supportAudio`. They map to
`enableVisionModality` and `enableAudioModality` on the native session. Set
neither and you get a text session. Set one and the same weights will take
pictures. Set both and they will take pictures and sound.

Nothing is downloaded in between, and nothing about the model changes: a
`.litertlm` file ships whatever encoders it was built with, and a session
decides which of them are wired up.

Which is also the limit of the idea, and Step 3 walks straight into it. A flag
can only switch on an encoder that is in the file. Step 2's SmolVLM2 has a
vision encoder and no audio one, so `supportAudio: true` there is not a cheap
way to get sound — it asks for a part the checkpoint does not contain. Audio
means different weights, and different weights mean a download, not a boolean.

### What is not yours to decide

The flags are yours to set. Whether the platform honours them is not.

`flutter_edge_ai_litertlm`'s browser arm runs the upstream `@litert-lm/core`
package, and that JS API exposes **no vision executor and no audio executor**.
Setting `supportImage: true` there does not throw. The model loads, the chat
opens, and a debug build prints one warning. The refusal comes at the message:
`addQueryChunk` with an image in it throws `UnsupportedError`, and the turn
never reaches the model. (Before `flutter_edge_ai_litertlm` 1.11.3 it did not
throw — the bytes were dropped, and the model answered about a picture it
never received.)

An exception you can catch, and Step 2's `catch` does: the error lands where
the reply would have been. But it lands after the user has picked the photo
and typed the question. So by the end of this codelab the app asks first,
before it offers the button, and when the answer is no it says **which** no it
got:

```dart
  bool get available => byModel && byPlatform;

  /// Which side said no, and why. Null when both said yes.
  ///
  /// Both can refuse at once — a text-only model in a browser — and then the
  /// user deserves both halves, because fixing one changes nothing.
  String? get blockedBecause => switch ((byModel, byPlatform)) {
    (true, true) => null,
    (false, true) => modelReason,
    (true, false) => platformReason,
    (false, false) => '$modelReason, and $platformReason',
  };
```

*"This platform has no audio input"* reads very differently to a learner than a
greyed-out microphone. One is information; the other is a bug report waiting to
be filed.

## Step 2: Send a picture
Duration: 12

### Add the package

```bash
flutter pub add image_picker
```

`image_picker` declares all six platforms: a photo gallery on Android and iOS,
and a file dialog — through `file_selector` — on macOS, Windows, Linux and the
web. That single call is why this step needs no platform branching in the UI.

### One platform change

macOS runs sandboxed, and a sandboxed app cannot read a file the user picked
unless it says it will. Add one key to **both** `macos/Runner/DebugProfile.entitlements`
and `macos/Runner/Release.entitlements`:

```xml
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
```

Both files, not one: `Debug` is what `flutter run` uses and `Release` is what
you ship, and an entitlement added to only the first works perfectly until the
day it matters.

Android needs nothing — the system photo picker hands back a URI without a
permission. iOS needs nothing either: since iOS 14 `image_picker` uses
`PHPicker`, which runs out of process and requires no
`NSPhotoLibraryUsageDescription`. Windows, Linux and the web need nothing.

### The model

`step_02_vision` replaces Getting Started's Gemma 3 1B with something smaller
that can see:

```dart
  /// A vision-language model small enough to feel like a text model. 0.36 GB
  /// is roughly what a photo-heavy app already spends on its image cache, so
  /// this is the version of "multimodal" you can put in a shipping app
  /// without an argument about download size — about a minute of download,
  /// and then it is looking at your photograph.
  ///
  /// It cannot hear, and that is not a gap in this step: it is a
  /// vision-language model, and the plugin lists audio input for Gemma 4 and
  /// Gemma 3n only (`flutter_edge_ai/README.md`). A session flag cannot switch
  /// on an encoder the checkpoint does not carry. It is why Step 3
  /// changes models, and it is the model half of the question `complete` asks
  /// at the end — a half that says no here while the device, happily holding
  /// a microphone, says yes.
  /// Run on macOS 2026-09-07: installs (0.36 GB) and answers "RED" to a
  /// 16x16 red square, with `supportImage` set on both `getActiveModel` and
  /// `createChat`. Nothing in CI runs a model, so this line is the only
  /// evidence these weights were ever executed.
  static const smolVlm2 = ModelChoice(
    nativeLabel: 'SmolVLM2 500M',
    nativeUrl:
        'https://huggingface.co/litert-community/SmolVLM2-500M/resolve/main/'
        'SmolVLM2-500M.litertlm',
    nativeFileName: 'SmolVLM2-500M.litertlm',
    // `general` and not `gemmaIt`: SmolVLM2 is not a Gemma, and the chat
    // template that ships inside the `.litertlm` is the right one to use.
    nativeModelType: ModelType.general,
    nativeSize: '0.36 GB',
    // The web substitute: the same Gemma 4 E2B web build Step 3 uses.
    webLabel: 'Gemma 4 E2B',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    webFileName: 'gemma-4-E2B-it-web.litertlm',
    webModelType: ModelType.gemma4,
    webSize: '2.0 GB',
  );
```

Native only. The browser `.litertlm` runtime runs a dedicated web export of a
checkpoint, never the native file, and SmolVLM2 publishes no web export.
Install `SmolVLM2-500M.litertlm` in Chrome anyway and it downloads fine, then
fails at engine creation:

```text
Error: Streaming kTfLitePrefillDecode models is not supported yet.
```

So `ModelChoice` carries a native pair and a web pair, the same shape Step 3
uses for its own two builds of one checkpoint — except here the two platforms
do not even agree on which *model* it is. On the web this one resolves to the
Gemma 4 E2B web build: the exact pair Step 3 installs natively, just arriving
a step early. `modelType` has to follow the platform for the same reason the
URL does — `general` for SmolVLM2, `gemma4` for the substitute — and every call
site (`main.dart`'s gate, `download_page.dart`, `createChat`) reads it through
one getter, so the two can never drift apart the way two independently-set
fields could.

Run this step in Chrome and you get a real chat: the Gemma 4 E2B web build
talks, it just cannot see — vision is a native feature in this codelab, not
because of anything Step 2 does differently on the web, but because the
browser runtime has no vision executor for *any* checkpoint. The picture
button stays live all the same, here and in Step 3 — and so does Step 3's
microphone. Press either in a browser, pick the photo or record the clip, send
it, and the turn fails: `addQueryChunk` throws `UnsupportedError`, and the
`catch` in `_send` puts it in the reply bubble — *"⚠️ Unsupported operation:
Web LiteRT-LM does not support image input for LLMs yet…"*, or *audio input*
for a clip. Nothing reaches the model, and the next text-only turn works as
before. A debug build also prints one line at `createChat`, saying the
modalities were requested and an image or audio message will throw; a release
build does not, because `edgeAiLog` compiles out of release entirely. The error
in the bubble is there either way. It is an honest failure, and a late one: the
user did the work before anything said no. Step 4 moves the answer ahead of the
button, by asking the platform what it supports instead of assuming. For now
the point is narrower: SmolVLM2 never installs in a browser, and it fails
loudly rather than quietly when you try.

`ModelType.general` and not `gemmaIt` is still the right call for the native
build, but not for the reason it would be on an older format. On `.litertlm`
the prompt never gets a hand-built wrapper: the engine applies the chat
template baked into the file itself, on every platform this codelab targets,
so naming the wrong family here does not double the turn markers. (It used to,
on iOS — before the legacy `flutter_gemma` 1.8.3 release the SDK still wrapped
`.litertlm` prompts
by hand there, a leftover from when iOS ran the format through MediaPipe, so
the markers reached the model twice. Fixed now, everywhere.)

What `modelType` still decides for a `.litertlm` reply: which reasoning blocks
the SDK strips out of it — `<think>...</think>` for `deepSeek`, `qwen` and
`qwen3`, the `<|channel>thought` block for `gemmaIt` and `gemma4` — and which
format a tool call in the response is parsed with. SmolVLM2 reasons in neither
form and calls no tools, which is the real reason `general` is right here, not
a guard against a prompt that was never going to be corrupted.

0.36 GB is roughly a minute of download, on native. That is the reason this
step starts here: you should be reading a model's description of your own
photograph before you have finished reading this page, not waiting out a
multi-gigabyte download to find out whether the wiring is right. (On the web
the download is the 2.0 GB Gemma 4 build above, and there is no photograph to
read a description of — see the vision note above.)

The repository is ungated, so `main.dart` also loses the Hugging Face plumbing
it inherited from Getting Started. It gains a `try` in exchange:

```dart
  try {
    await FlutterEdgeAi.initialize(
      inferenceEngines: [LiteRtLmEngine()],
      // OPFS streaming, not the Cache API default: the web build is 2.0 GB,
      // right on the ~2 GB blob ceiling, so it is not worth buffering.
      webStorageMode: WebStorageMode.streaming,
    );
  } catch (error) {
    runApp(_StartupFailed(error: error));
    return;
  }
```

`webStorageMode` is the web half of this step, and it earns its own sentence.
It is not something the format demands: the browser engine takes either
storage mode — `flutter_edge_ai_litertlm`'s web arm accepts a Cache API blob URL
and an OPFS stream alike, and its own doc reserves streaming for models past
2 GB. What changed in the legacy `flutter_gemma` 0.16.2 release was that web
`.litertlm` inference
arrived at all, not that streaming became compulsory. The reason to set it
here is size. The default `WebStorageMode.cacheApi` buffers the whole download
in memory as one blob, and browsers cap a single blob at roughly 2 GB — Chrome
refuses past it with `ERR_BLOB_OUT_OF_MEMORY`. The Gemma 4 E2B web build this
step installs in the browser is 2.0 GB, right on that line. Close enough that
every `.litertlm` install in this codelab uses `WebStorageMode.streaming` from
here on: streaming writes the download into OPFS and reads the model back from
there instead of holding it whole in memory. It is not the only thing a web
install needs — Step 4 covers the rest.

That is not ceremony. This is the earliest thing in the app that can fail —
hot-restarting after adding a plugin throws `MissingPluginException` right here
— and an `await` before `runApp` that throws never reaches `runApp` at all. The
symptom is a blank window and a stack trace in a console you are probably not
looking at. Every other failure in this app arrives on screen; this one has to
be made to.

### Open a session that can see

One argument:

```dart
      final chat = await inference.createChat(
        modelType: widget.model.modelType,
        // The session half of "this chat can see". It maps to
        // `enableVisionModality` on the native session — a session flag, not a
        // different model: the same weights, opened with one more capability
        // switched on. The model half is the `supportImage` on
        // `getActiveModel` above, and both are required.
        supportImage: true,
        maxOutputTokens: 256,
      );
```

The call above it changes too — in two ways, one of them the trap just
described:

```dart
      // maxTokens is the CONTEXT WINDOW — prompt + history + reply share it.
      // It is NOT a reply-length cap; for that, pass maxOutputTokens below.
      // `InferenceChat` charges a message carrying an image a flat 257 tokens
      // against this budget — the SDK's own accounting, not a measurement of
      // the model, and it is per message, not per picture. 1024 is the floor
      // for a `.litertlm` model and what the earlier codelabs use; with
      // pictures in the history it stops buying a conversation, hence 4096.
      //
      // The modality flag belongs HERE as well as on the chat below. This is
      // where the engine is built, and it only loads a vision executor if it
      // is told to. Set it on the chat alone and everything looks fine until
      // the first image, when native fails the turn with
      // `INVALID_ARGUMENT: Vision executor should not be null`.
      final inference = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        supportImage: true,
      );
```

Worth knowing that images are not free inside that window: `InferenceChat`
charges a message carrying an image a flat **257 tokens** against `maxTokens`
in its own bookkeeping (`lib/core/chat.dart`), and trims the oldest history
when the total gets close. That is the SDK's accounting, not a measurement of
the model.

### Pick the image

The plugin takes **bytes**, not a path. That is why one code path covers a
phone's gallery and a desktop's file dialog:

```dart
  /// Reads a picture into memory. The plugin takes bytes, not a path — which
  /// is why this works the same on a phone and in a desktop file dialog.
  Future<void> _pickImage() async {
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        // The vision encoder resizes to its own input square anyway, so a
        // 12-megapixel original costs decode time and memory for nothing.
        maxWidth: 1024,
        maxHeight: 1024,
      );
      // Null means the user closed the picker. That is not an error, and
      // reporting it as one is how an app earns a reputation for shouting.
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (mounted) {
        setState(() {
          _image = bytes;
          _notice = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _notice = 'Could not read that image: $error');
      }
    }
  }
```

Two details worth keeping. `maxWidth` / `maxHeight` are not cosmetic: the
encoder resizes to its own input square anyway, so decoding a 12-megapixel
original costs time and memory for nothing — on a phone, sometimes an
out-of-memory kill. And a `null` file is the user closing the picker, not a
failure; an app that shows an error there is an app people learn to distrust.

### Send it

One line changes in `_send`: which factory builds the message.

```dart
      await chat.addQueryChunk(
        // One factory per shape of turn. `Message.withImages` takes a LIST —
        // the API is shaped for models that accept several pictures per turn —
        // but this app sends one, and one is what the engine is built for:
        // `getActiveModel` defaults `maxNumImages` to 1 when `supportImage` is
        // on, so raise it there before sending more than one here.
        // `Message.text` is the same call with no pixels attached.
        image == null
            ? Message.text(text: text, isUser: true)
            : Message.withImages(text: text, imageBytes: [image], isUser: true),
      );
```

Everything downstream — `generateChatResponseAsync`, the streaming loop, the
error handling — is byte-for-byte the code from Getting Started.

Run `step_02_vision` on a phone or a desktop, attach a photo, and ask what is
in it.

## Step 3: Seven times the size, paid once
Duration: 16

Step 2's model cannot hear. Not "audio is switched off" — SmolVLM2 has no audio
encoder in it at all, and a session flag cannot wire up a part that is not
there. So this step does the thing the rest of the codelab spends its time
telling you that you rarely need to do: it changes models.

**This step downloads 2.59 GB** on Android, iOS and desktop. On the web the
model is the 2.0 GB build Step 2 already used, because SmolVLM2 has no web
build of its own (see Step 2) — but this step app downloads it again; see
below. Gemma 4 E2B is seven times the size of SmolVLM2 on native, and there is
no honest way to shrink that number: audio needs weights that were trained
with it.

What you get for the seven times is the reason to stop here rather than keep
collecting: this one checkpoint reads pictures *and* hears you. You pay once.
The alternative — a vision model and an audio model, picked at run time — is
two downloads, two loads, both sets of weights resident the moment a user
switches input, and a conversation that cannot follow them across. `complete`
ships exactly one model, and it is this one.

### The model

```dart
  /// Gemma 4 E2B reads pictures and listens to audio with the same weights.
  ///
  /// Step 2's SmolVLM2 has no audio encoder, and a session flag cannot switch
  /// on something the checkpoint does not carry — so audio costs a second
  /// download, seven times the first at 2.59 GB. You pay it once: both
  /// modalities come out of these weights, so nothing here ever holds two
  /// models open to cover two kinds of input.
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    nativeUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    nativeFileName: 'gemma-4-E2B-it.litertlm',
    nativeSize: '2.59 GB',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    webFileName: 'gemma-4-E2B-it-web.litertlm',
    webSize: '2.0 GB',
    modelType: ModelType.gemma4,
  );
```

Two URLs, not one — the same `litert-community/gemma-4-E2B-it-litert-lm`
repository publishes a build for the native FFI engine and a separate one for
`@litert-lm/core`, the web arm. `ModelChoice.url` (and `.fileName`,
`.sizeLabel`) resolve to whichever pair matches with a single `kIsWeb` check,
so `main.dart` and `download_page.dart` read one property each and never
branch on platform themselves. The test suite checks both pairs directly —
`nativeFileName` against `nativeUrl`, `webFileName` against `webUrl` — because
a VM test never sets `kIsWeb`, so the getters alone would leave the web pair
unchecked.

The id changed **on native** — SmolVLM2's file name is not Gemma 4's — so the
download screen is back on the next launch there: the gate in `main.dart` asks
`isModelInstalled('gemma-4-E2B-it.litertlm')` and the answer is no. Step 2's
file is not deleted for you — every step app in this codelab shares one
application identity, so SmolVLM2 is still sitting exactly where it was. Press
the delete button in `step_02_vision` before you move on if you want that
0.36 GB back.

On the **web**, the model does not change. Step 2's own `ModelChoice` already
resolves to `gemma-4-E2B-it-web.litertlm` in the browser (see Step 2), so there
is no id to change, and Step 3's only contribution is the `supportAudio` flag
below. The download screen comes back all the same. Browser storage belongs to
one origin in one browser profile, and `flutter run -d chrome` runs each step
folder in a Chrome profile of its own (kept in that folder's
`.dart_tool/chrome-device`) and, unless you pass `--web-port`, on a random
port — a new origin, with no install record and no bytes. So
`isModelInstalled` answers no and the 2.0 GB comes down again. To share one
install record across the steps, serve every one of them from the same origin
— `flutter run -d web-server --web-port=8080`, then open
`http://localhost:8080` in the same Chrome window each time. The download
screen is then skipped, though a fresh page load still fetches the model over
the network, for the reason Getting Started gives in its Step 2.

### Add the package

```bash
flutter pub add record
```

`record` is for capture, not for the model — the microphone, not the weights.

### The platform changes

Android needs nothing declared: `record` ships `RECORD_AUDIO` in its own
manifest, the manifest merger adds it to yours, and `record` asks the user for
it at run time.

iOS, in `ios/Runner/Info.plist` — the string is shown to the user, so write it
as if a reviewer will read it, because one will:

```xml
	<key>NSMicrophoneUsageDescription</key>
	<string>Recordings are sent to a language model running on this device. Nothing leaves the phone.</string>
```

macOS asks through the same key, so add it to `macos/Runner/Info.plist` as
well:

```xml
	<key>NSMicrophoneUsageDescription</key>
	<string>Recordings are sent to a language model running on this Mac. Nothing leaves the machine.</string>
```

…and, in **both** entitlements files again:

```xml
	<key>com.apple.security.device.audio-input</key>
	<true/>
```

Windows and Linux need nothing declared either.

### One more flag, in both places

On the session:

```dart
      final chat = await inference.createChat(
        modelType: widget.model.modelType,
        // Two flags, ONE model. They map to `enableVisionModality` and
        // `enableAudioModality` on the native session. Step 2's model had no
        // audio encoder for a flag to switch on, which is what the 2.59 GB
        // bought — and it bought both: the weights that describe your
        // photograph are the weights that hear you, so this app never opens a
        // second model to cover a second modality.
        supportImage: true,
        supportAudio: true,
        maxOutputTokens: 256,
      );
```

and — for exactly the reason Step 2 gave — on the call above it that builds the
engine, because that is where the audio executor is loaded or not loaded:

```dart
      final inference = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        supportImage: true,
        supportAudio: true,
      );
```

Two lines, in two calls. Together with the constant above, that is the entire
model-side change in this step; everything below is about getting sixteen
kilohertz of mono PCM out of a microphone.

### Capture without a file

`record.start()` writes to a path — and getting a writable path on every
platform means `path_provider`, which imports `dart:io` and therefore cannot be
compiled for the web. This app has to compile for the web whether or not audio
works there, so it uses `startStream` instead: the samples arrive in Dart and
the clip never touches disk.

```dart
      _pcm.clear();
      final done = Completer<void>();
      final stream = await _recorder.startStream(
        const RecordConfig(
          // Raw PCM, not a container: `startStream` hands the samples to Dart
          // instead of writing a file, so nothing here needs a writable path.
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: _channels,
        ),
      );
```

16 kHz mono is what the model's audio front end wants:

```dart
/// The recorder asks for these, and [wavFromPcm16] writes them into the
/// header. 16 kHz mono is what the model's audio front end wants; sending it
/// 44.1 kHz stereo means resampling somewhere, and the somewhere is native
/// code you cannot see.
const _sampleRate = 16000;
const _channels = 1;
```

Raw PCM is not a file format, so `lib/wav.dart` puts a forty-four-byte header
in front of it. There is nothing clever in it, and that is the point — the
whole cost of not taking a sixth dependency is one small, testable function:

```dart
  ascii(0, 'RIFF');
  // Everything after this field: 44 - 8 header bytes, plus the samples.
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // fmt chunk length
  header.setUint16(20, 1, Endian.little); // 1 = uncompressed PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
```

A wrong length or a wrong sample rate here does not crash. It makes the model
hear the clip at the wrong speed, which reads to everyone as a bad model — so
`test/widget_test.dart` asserts every field of that header.

### Stop, and wait for the last bytes

```dart
      await _recorder.stop();
      // `stop()` returns before the platform has flushed its last buffers.
      // The stream's done event is what says every sample arrived; the
      // timeout is there so a platform that never closes it cannot hang the
      // button, at the cost of the final fraction of a second.
      await _samplesDone?.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
```

`stop()` returning is not the same as the samples having arrived. Cancel the
subscription there and you truncate the clip — usually by a fraction of a
second, occasionally by the last word of the question.

### The microphone is its own question

```dart
  /// Starts capture, collecting raw samples in memory.
  ///
  /// `hasPermission()` is the device's own answer, and it is not the model's
  /// or the platform's: on a simulator with no input device, or after the
  /// user has declined once, it is false however capable the rest is.
  Future<void> _startRecording() async {
```

### One attachment, by construction

A picture and a clip are alternatives, not a pair — a turn carrying both is a
question about neither. So the queued attachment is one field, not two:

```dart
/// What can ride along with a message.
enum _AttachmentKind { image, audio }

/// The thing queued for the next message: one kind, its bytes.
///
/// One record instead of an `_image` and an `_audio` field, because "at most
/// one attachment" is then the shape of the state rather than an invariant
/// three scattered lines have to remember. Two nullable fields can hold both at
/// once, and the sender would have to pick one — silently, which is the exact
/// failure this codelab is about.
typedef _Attached = ({_AttachmentKind kind, Uint8List bytes});
```

Assigning one replaces the other, so nothing has to remember to clear anything.
And `_send` picks the factory that matches what is attached:

```dart
  Message _message(String text, _Attached? attached) => switch (attached) {
    null => Message.text(text: text, isUser: true),
    (kind: _AttachmentKind.image, :final bytes) => Message.withImages(
      text: text,
      imageBytes: [bytes],
      isUser: true,
    ),
    (kind: _AttachmentKind.audio, :final bytes) => Message.withAudio(
      text: text,
      audioBytes: bytes,
      isUser: true,
    ),
  };
```

`Message.withImages` takes a LIST — the API is shaped for models that accept
several pictures per turn — but this app sends one, and one is what the engine
is built for: `getActiveModel` defaults `maxNumImages` to 1 when `supportImage`
is on, so raise it there before sending more than one here.

Run `step_03_audio` on a phone or a desktop. Record a few seconds asking the
model something, and watch the same streaming loop answer it — then attach a
photo to the very next turn. Same session, same weights, nothing else opened:
that is what the 2.59 GB was for.

## Step 4: Ask what this platform allows
Duration: 9

`step_03_audio` sets both flags to `true` unconditionally. On Android, iOS,
macOS, Windows and Linux that is correct. Run it in Chrome and it is a promise
the app cannot keep: both buttons are live, the user attaches a photo or
records a question, and only on send does the runtime refuse it — an
`UnsupportedError` where the answer should be. Better not to offer a button
whose result the runtime will refuse than to let the user attach and then fail.

`complete` fixes that by asking first, and it asks two things.

### Two questions, and a name for the answer

The **model half** is a property of the checkpoint — the same answer on a
Pixel, a Mac and in Chrome:

```dart
  /// What the WEIGHTS accept. Properties of the checkpoint, not of the
  /// device: the same answer on a Pixel, on a Mac and in Chrome. They are
  /// only half of "can this app send one" — the other half is in
  /// `capabilities.dart`. Both halves really do refuse things, and they refuse
  /// different ones: Step 2's SmolVLM2 answers no to audio on a device holding
  /// a microphone, while this model answers yes to both on a platform that
  /// will carry neither.
  final bool supportsImage;
  final bool supportsAudio;
```

The **platform half** is not:

```dart
  /// Image input reaches the model on all five native platforms — Android,
  /// iOS, macOS, Windows and Linux.
  ///
  /// Not on the web: `flutter_edge_ai_litertlm`'s browser arm runs the upstream
  /// `@litert-lm/core` package, whose JS API exposes no vision executor, so a
  /// message carrying an image **throws `UnsupportedError`** when it is sent.
  /// The refusal is honest, but it comes late — after the user has picked the
  /// photo and typed the question — which is exactly why the app asks this
  /// before it offers the button.
  static bool get image => !kIsWeb;
```

Both are needed. Keeping only the AND would work and would tell the user
nothing; `Capability` keeps the two answers apart precisely so it can name the
one that refused.

And you have met both refusals already, one per model. Run `complete` in Chrome
and the platform half says no while the weights have not changed at all. Hand
these same factories Step 2's SmolVLM2 and the **model** half says no to audio,
on a phone whose microphone was never in question. "Not supported" covers both
and helps with neither: one is fixed by opening the app somewhere else, the
other by downloading different weights, and the app is the only thing in the
room that knows which.

### The flags stop being constants

```dart
      final chat = await inference.createChat(
        modelType: widget.model.modelType,
        // Still two session flags on one model — but no longer hard-coded
        // `true`. Each is the AND of both answers: what the weights accept
        // and what this platform will carry to them. Asking for a modality
        // the platform cannot deliver buys nothing: on the web the session
        // still opens, and the first picture or clip sent to it throws.
        supportImage: _imageCapability.available,
        supportAudio: _audioCapability.available,
        maxOutputTokens: 256,
      );
```

Both places again — the engine has to be built with the same answer, or the
executor the session asks for was never loaded:

```dart
      final inference = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        supportImage: _imageCapability.available,
        supportAudio: _audioCapability.available,
      );
```

One `Capability` feeds both calls, which is the point of computing it once:
two independently derived booleans are two things that can drift apart, and
this is the drift that costs 2.59 GB to discover.

### Say it out loud

A greyed-out button is not an explanation, so the app prints one:

```dart
/// One line naming a modality this app cannot use here, and which side of the
/// question refused it. Renders nothing when the modality works.
class _BlockedLine extends StatelessWidget {
  const _BlockedLine({required this.capability});

  final Capability capability;

  @override
  Widget build(BuildContext context) {
    final why = capability.blockedBecause;
    if (why == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Text(
        '${capability.what} is off — $why.',
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
```

Note what this widget does *not* take: a label. `Capability` carries its own
`what` — "Image input", "Audio input" — set by the factory that already knows
which modality it is. A separate label argument compiles just as happily when
it is paired with the wrong answer, and renders *"Audio input is off — Gemma 4
E2B has no vision encoder"*: a confident, fluent sentence about something that
never happened, which is the failure this codelab was written against.

The app bar carries the same verdict in two words, always visible:

```dart
            child: Text(
              'image ${_imageCapability.available ? 'on' : 'off'} · '
              'audio ${_audioCapability.available ? 'on' : 'off'}',
              style: theme.textTheme.labelSmall,
            ),
```

and the info button opens the screen this whole codelab exists for. It never
says "not supported". It shows both answers separately, with the reason
underneath:

```dart
  static Widget _row(BuildContext context, Capability c) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(c.what, style: theme.textTheme.titleSmall),
        Text('the model: ${c.byModel ? 'yes' : 'no'}'),
        Text('this platform: ${c.byPlatform ? 'yes' : 'no'}'),
        if (c.blockedBecause case final why?)
          Text(
            why,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          )
        else
          Text('available', style: theme.textTheme.bodySmall),
      ],
    );
  }
```

Run `complete` natively and both rows read *yes / yes*. Run it in Chrome and
the model rows do not move — the weights did not change — while both platform
rows flip to *no*. Two independent facts, visibly independent.

### The platform matrix, as it really is

| | Android | iOS device | iOS Simulator | macOS | Windows | Linux | Web |
|---|---|---|---|---|---|---|---|
| Text | yes | yes | CPU only | yes | yes | yes | yes |
| Image input | yes | yes | CPU only | yes | yes | yes | **no** |
| Audio input | yes | yes | no microphone | yes | yes | yes | **no** |
| GPU | yes | yes | **no** | yes | yes | yes | required |

Two of those columns deserve a sentence each.

**The web** is a `no` for both modalities, and it is not a bug in your setup.
The `.litertlm` browser runtime is an early preview of `@litert-lm/core` and it
is text-only. What a learner should expect there: the app loads, the model
downloads, text chat works, and both attachment buttons are disabled with a
line naming the runtime that refused. That is the app working correctly. (Full
vision on the web today means MediaPipe `.task` models and the
`flutter_edge_ai_mediapipe` package — a different engine, documented in
[MediaPipe](/docs/mediapipe); the Inference Engines codelab pairs LiteRT-LM with
built-in AI instead, so it is not the place to look for this one.)

That "the model downloads" is not automatic, and it is worth naming what makes
it true, because none of it is specific to this codelab. Every step's
`web/index.html` loads `cache_api.js` and `opfs_helper.js` after the
`litertLmReady` handshake — copied byte-for-byte from `flutter_edge_ai`'s own
`web/` directory (`grep -A1 '"name": "flutter_edge_ai"'
.dart_tool/package_config.json` finds it in your own project) — because core's
web storage reaches OPFS through `window.flutterGemmaOPFS` in `opfs_helper.js`
and the Cache API through `window.cacheHas` and friends in `cache_api.js`, and
streaming mode uses both. Not as alternatives — on different paths. The
download itself goes to OPFS and never touches the Cache API. But the
`opfs://` mapping it registers lives in memory, so after a reload core's
lookup for an installed model finds nothing and asks the Cache API to restore
a URL before it gives up. Ship only `opfs_helper.js` and that restore call
hits an undefined global, the `catch` around it swallows the error, and an app
that still reads "installed" silently re-downloads the whole model.
`FlutterEdgeAi.initialize` passes `webStorageMode: WebStorageMode.streaming`
from Step 2 on, which is what routes those bytes through OPFS rather than the
Cache API default; see
Step 2 for why a 2 GB model is streamed rather than buffered. And `model.dart`
installs a different file on the web than everywhere else —
`gemma-4-E2B-it-web.litertlm` rather than `gemma-4-E2B-it.litertlm`, a separate
build of the same checkpoint built for `@litert-lm/core` (see Step 3). All
three are invisible to the compiler: the web build still compiles and still
runs `flutter analyze` clean without them. Drop the scripts or the web model
file and a learner finds out in the browser, at install or at engine creation.

**The iOS Simulator** is the case the two questions do not cover, and the
reason is not that Dart cannot see it — `device_info_plus` exposes
`IosDeviceInfo.isPhysicalDevice` for exactly this. It is that the Simulator is
a *supported* configuration rather than a refused one, so a flat "no" here
would be the wrong answer. The SDK runs it CPU-only, because Metal's simulator
implementation caps a single allocation at 256 MB, far below this model's
weights. A learner on a simulator should expect a 2.59 GB model to crawl if it
loads at all, and should move to hardware for the real thing; the app reports
whatever happens as a load error rather than pretending. That is a third axis —
this device, and what its memory and hardware will stand — and `Capability`
says out loud that it does not model it.

**Android, a real iPhone, and the three desktops** are the unrestricted case:
both modalities, GPU accelerated, no caveats.

### Try it end to end

`complete` ships an integration test that downloads the model, opens one
session with both flags set to whatever the platform allows, and sends a real
image through it. It needs a device and a 2.59 GB download, so it is not part
of CI:

```bash
cd codelabs/multimodal-flutter-gemma/complete
flutter test integration_test/multimodal_test.dart -d <device-id>
```

## What's next
Duration: 2

Two downloads, two modalities, one model at the end — and an app that knows
where it can use them.

* **Function calling** turns the model's answer into an action, and the same
  `createChat` grows a `tools:` argument for it
* **Speech-to-text** (`flutter_edge_ai_speech`) is the other way to use a
  microphone: transcribe first, then send text — which works on models with no
  audio encoder at all, Step 2's SmolVLM2 among them, and is often the cheaper
  design
* **MediaPipe** (`flutter_edge_ai_mediapipe`) opens `.task` models and is the
  engine to reach for when vision on the **web** is a requirement

### Reference

* [flutter_edge_ai on pub.dev](https://pub.dev/packages/flutter_edge_ai) — the full
  platform support matrix, including the web `.litertlm` limitations
* [Multimodal documentation](/docs/multimodal)
* [Source and this codelab's code](https://github.com/DenisovAV/flutter_edge_ai)
