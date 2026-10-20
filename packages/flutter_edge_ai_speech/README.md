# flutter_edge_ai_speech

> **Renamed from [`flutter_gemma_speech`](https://pub.dev/packages/flutter_gemma_speech).** Same package, new name:
> swap the dependency and the `package:flutter_gemma_speech/` imports; nothing on the device
> changes. See the [migration guide](https://flutteredge.ai/docs/migration).

On-device speech for [flutter_edge_ai](https://pub.dev/packages/flutter_edge_ai) — STT,
TTS, and a `VoiceSession` voice loop — via the LiteRT C API + `dart:ffi`. Opt-in
package: add it only if your app needs speech-to-text, text-to-speech, or a
push-to-talk voice loop.

This package depends on `flutter_edge_ai_litertlm`, which owns the shared `libLiteRtLm`
native bundle and exposes the LiteRT C API bindings (`LiteRtBindings`) used here.

## Status

- **STT** works end-to-end for **moonshine-tiny** (raw-PCM seq2seq), **Whisper**
  and **Parakeet** (log-mel) via `LiteRtSttBackend`.
- **TTS** works end-to-end for **Matcha** (`litert-community/Matcha-TTS`, 22050 Hz
  — a 3-graph LiteRT pipeline: encoder → CFM decoder → HiFi-GAN vocoder,
  producing 16-bit PCM), **Qwen3-TTS** and **Inflect-Nano-v2** (both 24000 Hz) via
  `LiteRtTtsBackend`; `kokoro`/`supertonic` are follow-ons.

Both backends are pure factories (`canHandle` always `true`) — the *model* is
selected per-install via `SttModelType` / `TtsModelType`, not the backend.

## Teach your AI assistant this package

```bash
dart run skills@ get --all
```

Installs the agent skills `flutter_edge_ai` bundles — this package depends on it, so they come with it. One of them, `flutter-edge-ai-speech`, covers STT and TTS model choice, the 16 kHz mono PCM input contract, and the Whisper output language — which is a property of a *transcription*, not of the loaded model.

## Usage

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

await FlutterEdgeAi.initialize(
  sttBackends: [LiteRtSttBackend()],
  ttsBackends: [LiteRtTtsBackend()],
);

// Text-to-speech (Matcha): install the registry's bundle once (pinned to a
// Hugging Face commit), then synthesize.
await FlutterEdgeAi.installFromCatalog(LiteRtSpeechModels.matchaTts.bundle)
    .install();

final synth = await FlutterEdgeAi.getActiveTts();
final pcm = await synth.synthesize('Hello world.'); // Uint8List, 16-bit PCM
print(synth.sampleRate); // 22050
await synth.close();
```

A recognizer's or synthesizer's `close()` frees its native model even
mid-request: requests that have not started fail with a `StateError`, the one in
flight finishes, and `close()` returns once the model is freed, printing a
warning if that takes over 30 s. Before 0.5.5 such a close could leave the model
resident.

A voice can also ship with the app: `fromAsset(directory)` and
`fromFile(directory)` take a directory laid out like the Hugging Face repo, and
`fromBundled()` (Android and iOS only) takes native resources named
`<type>__<file>` (`matcha__config.json`). See
[Voice files shipped with the app](https://flutteredge.ai/docs/speech#voice-files-shipped-with-the-app).

Speech-to-text installs a model and a tokenizer; a catalog build carries both:

```dart
await FlutterEdgeAi.installFromCatalog(LiteRtSpeechModels.whisperTiny.f32)
    .install();
```

`LiteRtSpeechModels` (0.5.10, with `flutter_edge_ai` 2.5.1 and
`flutter_edge_ai_litertlm` 1.16.1) lists every speech-to-text and
text-to-speech build, each pinned to a Hugging Face commit; `installStt()` and
`installTts()` still install your own files. Every build, and where each has
been run: [Model Registry](https://flutteredge.ai/docs/registry).

`transcribe` takes raw 16 kHz mono 16-bit little-endian PCM (`Uint8List`), not a
WAV file. Each model has a fixed window — 5 s for moonshine and Parakeet, 30 s
for Whisper; shorter audio is zero-padded and longer audio is silently
truncated.

### Speech-to-text output language (Whisper)

Whisper's shipped checkpoints are multilingual. The output language is one token
in the decoder's seed prompt, rebuilt per transcription — so it is a per-call
knob, and switching it never reloads the model:

```dart
final recognizer = await FlutterEdgeAi.getActiveStt(language: 'de');
final german = await recognizer.transcribe(germanPcm);

// Same recognizer, one call in French.
final french = await recognizer.transcribe(frenchPcm, language: 'fr');
```

Codes are Whisper's own, without the delimiters (`'en'`, `'de'`, `'uk'`);
default `'en'`. The setting changes what the model WRITES, not what it hears —
`'en'` on German audio returns an English translation, not an error. moonshine
and Parakeet have no language token and throw `ArgumentError` rather than
ignoring the value.

## Voice loop

`VoiceSession` chains STT → LLM → TTS into one push-to-talk turn with barge-in.
The loop also needs an LLM: add `flutter_edge_ai_litertlm`, pass
`inferenceEngines: [LiteRtLmEngine()]` to `initialize`, and install a
`.litertlm` model.
`VoiceSession.fromChat` wraps an `InferenceChat`. A chat with tools is supported
— pass `onToolCall` and the turn runs through the tool loop; it throws only if a
tools-enabled chat arrives without a handler. Use `VoiceSession.custom` for an
`AgentSession`/MCP responder. `runTurn` takes recorded PCM and streams back
`VoiceEvent`s.

```dart
final recognizer = await FlutterEdgeAi.getActiveStt();
final synthesizer = await FlutterEdgeAi.getActiveTts();
final chat = await (await FlutterEdgeAi.getActiveModel(maxTokens: 1024))
    .createChat(tokenBuffer: 256, maxOutputTokens: 128); // no tools, short replies

final session = VoiceSession.fromChat(
  recognizer: recognizer, chat: chat, synthesizer: synthesizer);

await for (final event in session.runTurn(pcm16kMono)) {
  switch (event) {
    case VoiceTranscriptEvent(:final text): /* show */
    case VoiceReplyTextEvent(:final chunk): /* stream */
    case VoiceReplyAudioEvent(:final pcm, :final sampleRate): /* play */
    case VoiceTurnInterruptedEvent(): /* stop player */
    case VoiceTurnCompleteEvent(): case VoiceErrorEvent(): break;
  }
}
// Barge-in: await session.interrupt();
```

`VoiceSession` owns no microphone or player — the app captures PCM
(`package:record`) and plays the reply (the example's own
`AudioConverter.pcmToWav` helper + `package:just_audio`), exactly as the example
`stt_screen`/`tts_screen` do.

### Audio turns: the model hears the recording

A model with an audio encoder (Gemma 4 or Gemma 3n E2B/E4B, as `.litertlm`) can take the recording itself.
`runAudioTurn` skips speech-to-text: it wraps the PCM in a WAV header,
`fromChat` sends that to the chat, and the reply is spoken as in `runTurn`. Load the
model and create the chat with `supportAudio: true`:

```dart
final model = await FlutterEdgeAi.getActiveModel(
  maxTokens: 4096,
  supportAudio: true, // loads the audio encoder
);
final chat = await model.createChat(supportAudio: true, maxOutputTokens: 128);
final session = VoiceSession.fromChat(
  recognizer: recognizer, chat: chat, synthesizer: synthesizer);

await for (final event in session.runAudioTurn(pcm16kMono)) {
  // the events of runTurn, without VoiceTranscriptEvent
}
```

Barge-in and the one-turn-at-a-time rule work as in `runTurn`; the complete and
interrupted events carry an empty transcript, and a recording under 2 bytes (a
push-to-talk tap) completes without asking the model. After a barge-in a
`.litertlm` chat keeps what was said in earlier audio turns with
`flutter_edge_ai_litertlm` 1.15.0 and later; with 1.14.0 and earlier, and
on the NPU, it rebuilds its conversation from text and forgets it. `createChat` takes
`supportAudio` from the model unless you pass it on native `.litertlm`, MediaPipe
Android/iOS and `flutter_edge_ai_llama` models; other engines default it to
false. On a chat whose
`supportAudio` is false, `runAudioTurn` throws a `StateError`. With
`VoiceSession.custom`, pass `respondToAudio` to the `VoiceResponder`: it gets
the recording as that WAV, which `AgentSession.ask(audioBytes:)` takes as is.
Audio input is native-only.

## Platforms

| Platform | STT | TTS |
|----------|-----|-----|
| Android / iOS | ✅ FFI (Android: `arm64-v8a`, `minSdk 30`) | ✅ FFI (Android: `arm64-v8a`, `minSdk 30`) |
| macOS / Linux / Windows | ✅ FFI | ✅ FFI |
| Web | ❌ stub `UnsupportedError` | ❌ stub `UnsupportedError` |

The grid is where the package runs, not where each model has been run:
Parakeet CTC (2.35 GB) is documented on desktop only and Qwen3-TTS on macOS
only. Per build and platform: https://flutteredge.ai/docs/registry.

No `hook/build.dart` of its own — the native library is bundled by
`flutter_edge_ai_litertlm`'s Native Assets hook and shared transitively.
