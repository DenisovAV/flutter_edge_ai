author: Sasha Denisov
summary: Building an Offline Voice Assistant in Flutter — STT, LLM, and TTS
id: voice-assistant-flutter-gemma
categories: flutter, ai, gemma, speech
environments: android, ios, macos
status: Published

# Building an Offline Voice Assistant in Flutter: STT, LLM, and TTS

## Overview
Duration: 3

### What you'll build

A voice assistant that runs entirely on the device. You ask it a question out
loud; it transcribes you, thinks, and answers out loud — with the network
switched off.

By the end you will have an app that:

* listens through the microphone and turns speech into text on-device
* answers with Gemma 4 and reads the answer out with an on-device voice
* starts speaking while the model is still writing the rest of the answer
* stops mid-sentence when you talk over it, and answers your next question
* tells the time and sets timers by calling functions in your own app

### What you'll learn

Three models are in play, and most of what makes a voice app work well happens
between them:

* why a recognizer takes **16 kHz mono PCM** and nothing else, and how to get
  exactly that out of the microphone without converting anything
* why a model that is already downloaded still has to be **installed again** on
  every launch
* why the reply audio needs a WAV header before a player will touch it, and why
  its sample rate is not the one you recorded at
* what changes when every word the model writes is going to be **heard**, not
  read
* how to start speaking before the reply is finished, and how to stop cleanly
  when the user interrupts
* how function calling fits into a voice turn, and why the typed path needs it
  too

### What you'll need

* Flutter **3.44** or newer
* An arm64 Android device or emulator, an iOS device, or an Apple-silicon Mac.
  Speech runs through `dart:ffi`, which the browser does not have, so there is
  no web target in this codelab
* About 2.8 GB free: Gemma 4 E2B is 2.59 GB, speech recognition 109 MB and the
  voice about 36 MB. On a phone, **6 GB of RAM or more** — the language model
  alone takes about 2.4 GB of it
* No Hugging Face account: all three models are ungated

**Watch out:** This codelab starts from the finished app of [Getting Started with On-Device LLMs](/codelabs/getting-started-flutter-gemma) — byte for byte, a CI check enforces it. If you have not done that codelab, `step_01_starter` still runs on its own; you will just be meeting the download-and-chat code for the first time.

### Get the code

Every step of this codelab exists as a complete, runnable app, so you can join
at any point or check your work against the next one.

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/voice-assistant-flutter-gemma
ls
```

```text
step_01_starter/     the chat app you start from
step_02_hear/        after Step 2 — it listens
step_03_speak/       after Step 3 — it answers out loud
step_04_loop/        after Step 4 — one voice turn, end to end
step_05_barge_in/    after Step 5 — streamed speech you can interrupt
step_06_tools/       after Step 6 — it calls your functions
complete/            the finished app
```

## Step 1: The starter app
Duration: 3

Open `step_01_starter` and run it.

```bash
cd step_01_starter
flutter run
```

It is the finished app from Getting Started: it downloads a model once, then
chats with it offline, streaming the reply as it is generated.

A voice assistant is that chat with two more models wrapped around it:

1. **Speech-to-text** turns what you said into the text the chat already takes.
2. The **language model** answers, exactly as it does now.
3. **Text-to-speech** turns the answer into audio.

Steps 2 and 3 add the two new models. Step 4 hands all three to one object that
runs them in order, and Steps 5 and 6 make the result feel like an assistant
rather than a pipeline.

## Step 2: Hear
Duration: 12

### Pick the model that will answer

The starter defaults to Gemma 3 1B, which needs a Hugging Face token. For a voice
assistant, use Gemma 4 E2B instead — `Models.gemma4`, already in `model.dart` as
Getting Started's no-account option. It is ungated, and — this matters in
Step 6 — it is the smallest Gemma that calls a tool and then says something
sensible about the result.

Point the app at it in `lib/main.dart`:

```dart
const _model = Models.gemma4;
```

The web branch goes away with this line. Speech runs through `dart:ffi`, which
the browser does not have, so from here on the app is Android, iOS and macOS.

### Add the packages

```bash
flutter pub add flutter_edge_ai_speech record
```

`flutter_edge_ai_speech` runs the speech models; the API it implements —
`installStt`, `getActiveStt` — is in core, the same split as the engine.
`record` is the microphone.

### Register the backend

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
  sttBackends: [const LiteRtSttBackend()],
  // huggingFaceToken and webStorageMode, as in the starter
);
```

Speech is opt-in the way engines are. Leave `sttBackends` out and
`getActiveStt()` throws, naming the package to add.

### Pick a speech model

`lib/model.dart` gets one more entry — moonshine tiny, English, 109 MB:

```dart
abstract final class Moonshine {
  static const modelUrl =
      'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/'
      'moonshine_tiny_5s_f32.tflite';
  static const tokenizerUrl =
      'https://huggingface.co/UsefulSensors/moonshine/resolve/main/'
      'ctranslate2/tiny/tokenizer.json';
  static const fileName = 'moonshine_tiny_5s_f32.tflite';
  static const maxRecording = Duration(seconds: 5);
}
```

Two files, from two different repositories: the `.tflite` turns audio into
token ids, and `tokenizer.json` turns those ids back into words.

**Good to know:** The `5s` in the file name is the model's input **window**. Audio past five seconds is not transcribed — it is cut off. That is why the app stops recording at `maxRecording` rather than letting you ramble into a limit you cannot see.

### Download it

`DownloadPage` installs the language model, then the recognizer:

```dart
await FlutterEdgeAi.installStt()
    .modelFromNetwork(Moonshine.modelUrl)
    .tokenizerFromNetwork(Moonshine.tokenizerUrl)
    .ofType(SttModelType.moonshine)
    .withModelProgress((percent) {
      if (mounted) setState(() => _percent = percent);
    })
    .install();
```

`ofType` picks the pipeline that runs the two files: moonshine, Whisper and
Parakeet are three different ones. And the gate in `main.dart` now asks for both
files before it lets the chat open:

```dart
Future<bool> _check() async =>
    await FlutterEdgeAi.isModelInstalled(widget.model.fileName) &&
    await FlutterEdgeAi.isModelInstalled(Moonshine.fileName);
```

### Install it again — every launch

This is the line that looks like a mistake. In `ChatPage._load`, after the chat
opens:

```dart
await FlutterEdgeAi.installStt()
    .modelFromNetwork(Moonshine.modelUrl)
    .tokenizerFromNetwork(Moonshine.tokenizerUrl)
    .ofType(SttModelType.moonshine)
    .install();
final stt = await FlutterEdgeAi.getActiveStt();
```

The gate already made sure the files are here, so this downloads nothing.
What it does is make moonshine the **active** speech model again. That choice
lives in memory and does not survive a restart, and `getActiveStt()` throws
without it. `install()` is idempotent: on files that are already there, it only
re-activates them.

### Record exactly what the model takes

The recognizer takes one format: 16 kHz, one channel, 16-bit little-endian
samples, no header. Ask the recorder for exactly that, as a stream:

```dart
final stream = await _recorder.startStream(
  const RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 16000,
    numChannels: 1,
  ),
);
final pcm = BytesBuilder(copy: false);
final done = Completer<void>();
stream.listen(pcm.add, onDone: done.complete, onError: done.completeError);
```

No file, no WAV to parse, no resampling — the bytes that arrive are the bytes
`transcribe` wants. When you tap the mic again:

```dart
await _recorder.stop();
await _micDone?.future;
final text = (await _stt!.transcribe(_pcm!.takeBytes())).trim();
await _send(text);
```

Waiting for `_micDone` is not ceremony: `stop()` closes the stream, and the last
chunk lands in the buffer just before it ends. Read the buffer on `stop()` alone
and you lose the tail of the sentence.

`_send` takes the transcript the way it takes typed text. The model never hears
audio; it gets words, the same as before.

### Ask for the microphone

Three platforms, three places:

* **Android** — `android/app/src/main/AndroidManifest.xml`:
  `<uses-permission android:name="android.permission.RECORD_AUDIO" />`
* **iOS** — `ios/Runner/Info.plist`: an `NSMicrophoneUsageDescription` string
* **macOS** — the same string in `macos/Runner/Info.plist`, **and**
  `com.apple.security.device.audio-input` set to `true` in both
  `DebugProfile.entitlements` and `Release.entitlements`

**Watch out:** Miss the macOS entitlement and nothing fails. The sandbox hands the app silence, the recognizer transcribes silence, and you get an empty transcript — which reads exactly like "I did not speak loudly enough".

### Run it

```bash
cd ../step_02_hear
flutter run
```

The first run downloads about 2.7 GB. Then tap the mic, ask a question, tap
again. The transcript appears as your message, and the model answers in text.

**Good to know:** Transcribing near-silence can produce words that were never said — that is a property of speech models, not a bug in the app. If you get a phantom question, you probably tapped stop before you spoke.

## Step 3: Speak
Duration: 10

### Add the packages

```bash
flutter pub add just_audio path_provider
```

`flutter_edge_ai_speech` already contains text-to-speech. What you need is
something to play its output, and a place to put the file the player reads.

### Register the backend and pick a voice

```dart
sttBackends: [const LiteRtSttBackend()],
ttsBackends: [const LiteRtTtsBackend()],
```

The voice is Inflect-Nano-v2: English, the fastest of the three the package
ships, and about 36 MB on disk. Its own two networks are 8 MB; the rest is the
pronunciation data it shares with Matcha-TTS, which the installer fetches from
the Matcha repository on its own. You give it one URL:

```dart
abstract final class Inflect {
  static const baseUrl =
      'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/';
}
```

```dart
await FlutterEdgeAi.installTts()
    .fromNetwork(Inflect.baseUrl)
    .ofType(TtsModelType.inflect)
    .install();
final tts = await FlutterEdgeAi.getActiveTts();
```

The same install-on-every-launch as Step 2, for the same reason.

### Give the samples a header

`synthesize` returns bare samples — numbers, with nothing saying how fast to
play them. A player needs to be told: one channel, so many samples per second,
16 bits each. That is all a WAV header is, and `lib/wav.dart` writes it:

```dart
Uint8List wavFromPcm16(Uint8List pcm, {required int sampleRate}) {
  const channels = 1;
  const bitsPerSample = 16;
  const blockAlign = channels * bitsPerSample ~/ 8;
  final header = ByteData(44)
    ..setUint32(0, 0x52494646) // "RIFF"
    ..setUint32(4, 36 + pcm.length, Endian.little)
    ..setUint32(8, 0x57415645) // "WAVE"
    // ...
    ..setUint32(24, sampleRate, Endian.little)
    // ...
    ..setUint32(40, pcm.length, Endian.little);
  // header, then the samples
}
```

**Watch out:** Use `tts.sampleRate`, never the 16 kHz you recorded at. Inflect speaks at **24 kHz**. Write 16000 into the header and the voice plays at two thirds of its speed, a fifth lower — recognisably the app, and recognisably wrong.

### Read the answer out

Once the whole reply is in:

```dart
Future<void> _speak(String text) async {
  final tts = _tts;
  if (tts == null || text.trim().isEmpty) return;

  final pcm = await tts.synthesize(text);
  if (pcm.isEmpty || !mounted) return;

  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/reply.wav');
  await file.writeAsBytes(wavFromPcm16(pcm, sampleRate: tts.sampleRate));
  await _player.setFilePath(file.path);
  unawaited(_player.play());
}
```

`play()` completes when playback **ends**, so it is not awaited: the composer
unlocks while the answer is still being read out. A reply with nothing
pronounceable — an emoji — comes back as zero bytes, and there is nothing to
play.

And when you start recording, stop the player first. Otherwise the microphone
records the app's own voice along with yours:

```dart
await _player.stop();
```

### Run it

Ask "What is the capital of France?". The answer appears, then you hear it.

Listen to how it says it. Gemma writes its answers for a screen, and a screen
answer has bold text and lists in it — `The capital of France is **Paris**.` The
voice copes with the asterisks, but the answer is still shaped for reading.
The next step fixes that at the source.

## Step 4: One voice loop
Duration: 10

### Write for the ear

Everything the model writes is now heard, so tell it:

```dart
const _spokenStyle =
    'You are a voice assistant. Your reply is read aloud by a speech '
    'synthesizer, so answer in one or two short sentences of plain spoken '
    'English. No markdown, lists, emoji or code.';
```

```dart
final chat = await inference.createChat(
  modelType: widget.model.modelType,
  systemInstruction: _spokenStyle,
  maxOutputTokens: 128,
);
```

The same question now comes back as `The capital of France is Paris.` A small
model takes an instruction like this literally, which is why it says what to
leave out as well as what to do.

**Good to know:** `maxOutputTokens` caps the **reply**. `maxTokens` on `getActiveModel` is the whole context window — prompt, history and reply together — and is not a length limit at all. A spoken answer that runs past two sentences is one nobody waits for.

### Hand the turn to VoiceSession

Steps 2 and 3 wired recognizer → chat → synthesizer by hand. `VoiceSession`
does that, in order, and reports what happened as events:

```dart
_session = VoiceSession.fromChat(
  recognizer: stt,
  chat: chat,
  synthesizer: tts,
);
```

It owns none of the three: the page still closes them. It does not own the
microphone or the speaker either. What it owns is the **order** — one turn at a
time, and a stop that reaches every stage. Step 5 is where that last part pays
off.

A recorded question now runs through one call:

```dart
await for (final event in _session!.runTurn(audio)) {
  switch (event) {
    case VoiceTranscriptEvent(:final text):
      // show what the user said
    case VoiceReplyTextEvent(:final chunk):
      // append to the reply bubble
    case VoiceReplyAudioEvent(:final pcm, :final sampleRate):
      await _play(pcm, sampleRate);
    case VoiceTurnCompleteEvent(:final transcript):
      // an empty transcript means nothing was heard
    case VoiceTurnInterruptedEvent():
    case VoiceErrorEvent():
      break;
  }
}
```

The `switch` is exhaustive over a sealed type, so an event the package adds
later fails to compile instead of being silently ignored.

Near-silence transcribes to nothing, and the session ends the turn right there
without asking the model anything — a turn with an empty transcript is
complete, not failed.

**Watch out:** A stage that **fails** — transcribe, generate, synthesize — arrives as an error on the stream, not as an event. `VoiceErrorEvent` is reserved and not emitted in this release. Wrap the loop in `try`/`catch`, or a failed turn looks like a turn that never ended.

The typed path stays as it was: a typed question goes straight to the chat and
through `_speak`. Both land in the same conversation.

### Run it

Talk to it. Transcript, reply and voice now come out of one call, and the
answers sound like answers.

## Step 5: Interrupt it
Duration: 12

Two things are still wrong. You wait for the whole answer to be written and
then synthesized before hearing a word. And once it starts talking, you cannot
stop it.

### Speak while the model is still writing

```dart
_session = VoiceSession.fromChat(
  recognizer: stt,
  chat: chat,
  synthesizer: tts,
  streamAudio: true,
);
```

With `streamAudio`, the session synthesizes the reply clause by clause as the
tokens arrive. You get several `VoiceReplyAudioEvent`s with `isFinal: false`,
then one empty one with `isFinal: true` that only says "that was all".

On an M4 Pro the first audio arrived about **0.6 s** after the question
finished — before the model had written its second sentence.

### Play clips in order

Several clips means a queue: they must play one after another, never on top of
each other, and a stop must silence the one playing **and** every one still
waiting. `lib/speaker.dart` is that queue:

```dart
void enqueue(Uint8List pcm, int sampleRate) {
  if (pcm.isEmpty) return;
  final generation = _generation;
  _tail = _tail.then((_) async {
    if (generation != _generation) return;
    // write the clip to a file, then:
    await _player.stop();
    await _player.setFilePath(file.path);
    if (generation != _generation) return;
    await _player.play();
  }).catchError((Object error) => onError(error));
}

Future<void> stop() async {
  _generation++;
  await _player.stop();
}
```

Each clip is chained onto the one before it. `stop()` bumps a generation
counter, so a clip queued before the stop sees the new number and skips itself.
The check runs a second time right before `play()`: a stop can land while the
file is being loaded, and without it a clip from before the barge-in plays over
the microphone that has just opened.

A clip that cannot be written or played goes to `onError`, which the page shows.
Dropping it quietly would leave a reply on screen that was never heard, with
nothing to say why.

**Watch out:** The `_player.stop()` before each clip is load-bearing. After a clip ends, `just_audio` still reports `playing`, and `play()` on a playing player returns at once **without playing anything**. Stopping first puts it back where `play()` means "play this".

### Barge in

A tap on the mic while the assistant is talking now stops it and starts
listening:

```dart
Future<void> _toggleMic() async {
  if (_listening || _opening) {
    await _stopListening();
    return;
  }
  _opening = true;
  try {
    await (_micStarting = _interruptThenListen());
  } finally {
    _opening = false;
  }
}

Future<void> _interruptThenListen() async {
  if (_turn != null) await _interrupt();
  await _startListening();
}

Future<void> _interrupt() async {
  await _speaker.stop();
  await _session?.interrupt();
  await _turn;
}
```

Silence first: the speaker stops in a millisecond, while the session has to
wait for generation to notice it was asked to stop. `interrupt()` stops the
model, drops any clause not yet synthesized, and completes once the turn has
ended with a `VoiceTurnInterruptedEvent`. The mic button stays enabled during a
voice turn for exactly this reason.

Opening the microphone takes a moment — a permission prompt the first time, the
recorder starting every time — and `_listening` turns true only at the end of
it. A second tap in that gap is a stop, not a second start: `_opening` routes it
to `_stopListening`, which waits for the whole opening, interrupt included,
before it stops.

### What the model remembers

The interrupted event carries what the model had written when it was stopped:

```dart
case VoiceTurnInterruptedEvent(:final partialReplyText):
  // mark the bubble "(interrupted)"
```

And the chat keeps it. After interrupting "Tell me three facts about the moon",
the history holds the question and the half-written answer, so the model knows
what it had already said. Your next question is answered on top of that.

**Good to know:** The interrupted-chat fix shipped in the legacy
`flutter_gemma_litertlm` **1.8.1** package and is present in the current
`flutter_edge_ai_litertlm`. Before that fix, a `.litertlm` chat stopped
mid-reply answered every later message with nothing. The package now rebuilds
the conversation from the chat's history on the first turn after a stop. That
history is replayed as text: an image or a recording sent in an earlier turn is
not part of it, so ask about it again with the image attached.

### Run it

Ask for three facts about the moon, and tap the mic while it is on the first
one. It stops mid-word, listens, and answers the next question in full.

## Step 6: Tools, by voice
Duration: 12

An assistant that can only talk is a chat with a speaker. This step lets it do
two things on the device: read the clock, and set a timer that the app keeps
and announces when it runs out.

### Declare the tools

`lib/tools.dart`:

```dart
const clockTool = Tool(
  name: 'get_current_time',
  description:
      'Return the current local time on this device. Use this whenever the '
      'answer depends on what time it is now.',
  parameters: {'type': 'object'},
);

const timerTool = Tool(
  name: 'set_timer',
  description: 'Start a countdown timer on this device.',
  parameters: {
    'type': 'object',
    'properties': {
      'minutes': {'type': 'number', 'description': 'Length in minutes.'},
    },
    'required': ['minutes'],
  },
);

const toolbox = [clockTool, timerTool];
```

The description is the only thing telling the model **when** to call, so it is
written as instruction. The clock takes no arguments and still declares
`parameters` with a `type` — without it, the model reads the declaration as cut
off.

Both tools are local and instant, so the assistant keeps working in airplane
mode.

### Implement them

```dart
Map<String, dynamic> run(FunctionCallResponse call) => switch (call.name) {
  'get_current_time' => {'time': _clock(DateTime.now())},
  'set_timer' => _setTimer(call.args['minutes']),
  _ => {'error': 'There is no tool called ${call.name}.'},
};
```

A tool is a Dart function from the arguments the model wrote to the map it will
be shown next. Check those arguments like any other input — the model can write
`"five"` or `0`, and can name a tool that does not exist. Answer that with an
`error` in the result, not an exception: the model reads it and can say what
went wrong.

When a timer runs out, nobody asked a question, so there is no turn to answer
in. The app says it directly:

```dart
Future<void> _timerDone(num minutes) async {
  final whole = minutes == minutes.roundToDouble() ? minutes.round() : minutes;
  final length = whole == 1 ? 'one minute' : '$whole minute';
  final text = 'Your $length timer is done.';
  if (!mounted) return;
  _say(text);
  await _speak(text);
}
```

### Give them to the chat and the session

```dart
final chat = await inference.createChat(
  modelType: widget.model.modelType,
  systemInstruction: _spokenStyle,
  maxOutputTokens: 128,
  tools: toolbox,
  supportsFunctionCalls: true,
);
```

```dart
_session = VoiceSession.fromChat(
  recognizer: stt,
  chat: chat,
  synthesizer: tts,
  streamAudio: true,
  onToolCall: _tools.run,
);
```

`onToolCall` is required once the chat has tools. Without it a tool call has
nothing to run, and the session refuses to start. The loop that sends the
result back and lets the model answer is the SDK's, not yours.

The typed path needs the same loop — the model may call a tool whichever way
the question arrived:

```dart
await for (final chunk in chat.generateChatResponseWithTools(
  onToolCall: _tools.run,
)) {
  // ...
}
```

### Run it

Ask "What time is it?". The model calls `get_current_time`, reads the result,
and says it: *It is currently twelve fifty-five.*

Run it a few times and sometimes you get *It is currently 2:27 PM.* instead. The
spoken-style instruction from Step 4 nudges the model toward numbers the way
they are said, and a small model does not follow a nudge every time. The words
are what the voice reads best: played back to the recognizer, "twelve
fifty-five" comes back as "1255", while "2:27 PM" comes back as "two, 27th M".

Then ask it to "set a timer for one minute", and a minute later the app tells
you it is done.

## Airplane mode
Duration: 3

Everything above runs on the device. Prove it: switch on airplane mode and
restart the app.

* The gate finds all three models already installed and goes straight to the
  chat.
* The launch-time `install()` calls download nothing — they only re-activate.
* Listening, answering, speaking, interrupting and both tools work as before.

What needs the network is the first run's download, and nothing else.

## What's next
Duration: 2

* **Other languages.** `SttModelType.whisper` understands 99 languages, and
  `getActiveStt(language: 'de')` picks the output one; Qwen3-TTS is the
  multilingual voice. Both are larger and slower than the models used here.
* **Pick the voice at run time.** The TTS model is one `ofType` away; Matcha is
  the other English voice the package ships.
* **Voice with your own documents.** The [On-Device RAG](/codelabs/on-device-rag-flutter-gemma)
  codelab builds retrieval; a `VoiceSession.custom` with your own responder
  puts it behind the microphone.
* **Fine-tune the tools.** The [Function Calling](/codelabs/function-calling-flutter-gemma)
  codelab trains a small model on your own tool set.
