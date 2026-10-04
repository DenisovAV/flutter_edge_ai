---
title: Speech
description: On-device speech for flutter_edge_ai — transcribe audio and synthesize speech fully offline. moonshine / Whisper / Parakeet STT + Matcha / Qwen3 / Inflect TTS, plus a voice loop, via the LiteRT C API and dart:ffi.
image: https://flutteredge.ai/images/og-image.png
---

`flutter_edge_ai_speech` is an opt-in satellite package that adds **on-device
speech** — speech-to-text and text-to-speech — to flutter_edge_ai. It runs
**selectable** models locally through the LiteRT C API + `dart:ffi` — no cloud,
no streaming a mic to a server.
You choose the model with `SttModelType` / `TtsModelType` and a profile-driven,
model-agnostic pipeline resolves the matching runtime, so it isn't tied to one
model. **moonshine**, **Whisper**, and **Parakeet** STT and **Matcha**,
**Qwen3-TTS** (multilingual) and **Inflect-Nano-v2** (fast) TTS work end-to-end
today; kokoro / supertonic TTS voices are follow-ons.

<Info>
Speech is a separate package so apps that don't need it don't ship the model or
the extra native surface. It depends on <code>flutter_edge_ai_litertlm</code>,
which owns the shared <code>libLiteRtLm</code> native bundle — no separate
native download.
</Info>

## Install

Add the core and the speech package. `flutter_edge_ai_speech` pulls in
`flutter_edge_ai_litertlm` (which owns the shared `libLiteRtLm` native bundle)
transitively — you don't add it yourself unless you also run `.litertlm`
inference.

```
dependencies:
  flutter_edge_ai: ^1.12.0
  flutter_edge_ai_speech: ^0.5.3
```

## Register the backend

STT is opt-in: pass `LiteRtSttBackend()` to `initialize()`. The backend is a
pure factory — the *model* is chosen per-install via `SttModelType`, not by the
backend.

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';

await FlutterEdgeAi.initialize(
  sttBackends: const [LiteRtSttBackend()],
);
```

## Install a model + transcribe

Install moonshine-tiny (model + tokenizer) once, then transcribe raw PCM. The
recognizer is created lazily by `getActiveStt()`.

```dart
// One-time install (downloads to the app's local storage).
await FlutterEdgeAi.installStt()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_f32.tflite',
    )
    .tokenizerFromNetwork(
      'https://huggingface.co/UsefulSensors/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json',
    )
    .ofType(SttModelType.moonshine)
    .install();

final recognizer = await FlutterEdgeAi.getActiveStt();

// pcm: 16 kHz mono 16-bit little-endian PCM bytes (Uint8List) — e.g. the data
// chunk of a WAV, or frames from a recorder. moonshine-tiny handles up to ~5 s.
final transcript = await recognizer.transcribe(pcm);
print(transcript); // "She had ... watch for all year."

await recognizer.close();
```

### Output language (Whisper)

Whisper's shipped checkpoints are multilingual, and the output language is one
token in the decoder's seed prompt. Set a default, or override a single call:

The install above is moonshine, which has no language token — `language:` throws
`ArgumentError` on it. Install Whisper first:

```dart
await FlutterEdgeAi.installStt()
    .modelFromNetwork('https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_f32.tflite')
    .tokenizerFromNetwork('https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json')
    .ofType(SttModelType.whisper)
    .install();
```

```dart
final recognizer = await FlutterEdgeAi.getActiveStt(language: 'de');
final german = await recognizer.transcribe(germanPcm);

// Same recognizer, one call in French — nothing is reloaded.
final french = await recognizer.transcribe(frenchPcm, language: 'fr');
```

`getActiveStt` returns a process-wide singleton, and calling it again with a new
`language` retargets that recognizer rather than rebuilding it — so you never
need to `close()` just to change language. Calling it with **no** `language`
clears the default you set earlier, back to the checkpoint's own `'en'`.

The code is Whisper's own, without the delimiters (`'en'`, `'de'`, `'uk'`), and
it defaults to `'en'`. It changes what the model WRITES, not what it hears:
asking for `'en'` on German audio returns an English translation, not an error.
An unknown or malformed code throws `ArgumentError`, as does any language on
moonshine or Parakeet — neither has a language token to set.

The moonshine repos are public, so no HuggingFace token is required. For gated
models pass a token to `initialize(huggingFaceToken: ...)` or per source
(`.modelFromNetwork(url, token: ...)`).

## Audio format

`transcribe()` takes **raw 16 kHz mono 16-bit little-endian PCM** (`Uint8List`)
— moonshine-tiny consumes samples directly, with no mel frontend. Configure your
recorder for 16 kHz / mono / 16-bit PCM. Starting from a WAV file, locate its
`data` chunk instead of skipping a fixed 44 bytes: recorders add `LIST`, `fact`
or padding chunks, and on iOS a multi-kilobyte `FLLR` block, so a fixed skip
feeds header bytes in as audio.

Each model also has a fixed window — 5 s for moonshine and Parakeet, 30 s for
Whisper. Shorter audio is zero-padded; **longer audio is silently truncated**, so
a 40-second clip on Whisper returns the first 30 seconds with no error. Split
long recordings yourself.

## Text-to-speech (Matcha)

TTS is opt-in the same way: pass `LiteRtTtsBackend()` to `initialize()`, then
install a voice and synthesize. **Matcha** (`litert-community/Matcha-TTS`) runs a
3-graph LiteRT pipeline (text-encoder → CFM decoder → HiFi-GAN vocoder) fully
on-device and returns 16-bit PCM at 22050 Hz.

```dart
await FlutterEdgeAi.initialize(
  ttsBackends: const [LiteRtTtsBackend()],
);

// One-time install of the Matcha bundle (downloads to the app's local storage).
await FlutterEdgeAi.installTts()
    .fromNetwork('https://huggingface.co/litert-community/Matcha-TTS/resolve/main/')
    .ofType(TtsModelType.matcha)
    .install();

final synth = await FlutterEdgeAi.getActiveTts();
final pcm = await synth.synthesize('Hello world.'); // Uint8List, 16-bit PCM
// Wrap with a 44-byte WAV header (synth.sampleRate == 22050, mono) to play it.
await synth.close();
```

The Matcha repo is public, so no HuggingFace token is required. Synthesis is
deterministic on a given arch — byte-identical on arm64, with imperceptible
low-float-bit divergence on x86_64.

### Qwen3-TTS (multilingual)

A second TTS family is selectable via `TtsModelType.qwen3` — an autoregressive
codec-LM (`litert-community/Qwen3-TTS-12Hz-0.6B-Base`, ~1.9 GB) that speaks 10
languages plus `'auto'` detection, picked with `getActiveTts(language:)`. Unlike
STT, the language is fixed when the synthesizer is created — `synthesize()` takes
no language — and `getActiveTts` returns a singleton, so asking it for a different
language throws `StateError` until you `close()` the current one. Same
install/synthesize API as Matcha, but heavier: CPU-only, 24 kHz output, RTF≈3
(~3 s of compute per 1 s of audio), and needs a 6 GB-RAM-class device.

```dart
await FlutterEdgeAi.installTts()
    .fromNetwork('https://huggingface.co/litert-community/Qwen3-TTS-12Hz-0.6B-Base/resolve/main/')
    .ofType(TtsModelType.qwen3)
    .install();

// language is a full lowercase name from qwen3SupportedLanguages ('english',
// 'german', … 10 of them) or 'auto' — not an ISO code, and ignored by Matcha.
final synth = await FlutterEdgeAi.getActiveTts(language: 'french');
final pcm = await synth.synthesize('Bonjour le monde.'); // Uint8List, 16-bit PCM
await synth.close();   // close before asking for another language
```

### Inflect-Nano-v2 (fast)

For snappy spoken replies, `TtsModelType.inflect` selects Inflect-Nano-v2 — a
tiny VITS voice (`sasha-denisov/inflect-nano-v2-litert`) and the fastest of the
three: it synthesizes much faster than it speaks. English-only; it reuses
Matcha's phonemizer bundle, so those G2P files are fetched cross-repo
automatically — about 36 MB in all, of which its own two networks are 8 MB.

```dart
await FlutterEdgeAi.installTts()
    .fromNetwork('https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/')
    .ofType(TtsModelType.inflect)
    .install();

final synth = await FlutterEdgeAi.getActiveTts();
final pcm = await synth.synthesize('Hello there!'); // Uint8List, 16-bit PCM @ 24 kHz
await synth.close();
```

## Voice loop

`VoiceSession` chains STT → LLM → TTS into one push-to-talk turn — transcribe,
generate a chat reply, synthesize it — streamed back as `VoiceEvent`s. Build
one with `VoiceSession.fromChat`, which wraps an `InferenceChat`. A tools-free
chat is the plain speech-to-speech loop; pass `onToolCall` to run function calls
inside a spoken turn (see [Tool calling](#tool-calling-in-the-voice-loop) below).

The loop needs an LLM as well as the two speech models: add
`flutter_edge_ai_litertlm`, register `inferenceEngines: [LiteRtLmEngine()]` in
`initialize`, and install a `.litertlm` model (see [LiteRT-LM](/docs/litertlm)) —
otherwise `getActiveModel` throws `StateError('No active inference model set')`.

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
```

`VoiceSession` owns no microphone or player — the app captures and plays PCM
itself, same as the STT/TTS sections above. For barge-in, call
`await session.interrupt()` while a turn is in flight: it stops generation,
bounded-drains the reply stream, and the turn ends with a
`VoiceTurnInterruptedEvent` instead of `VoiceTurnCompleteEvent`.

### Streaming audio (lower time-to-first-audio)

By default the reply is synthesized in one shot after the LLM finishes — a single
`VoiceReplyAudioEvent(isFinal: true)`. Pass `streamAudio: true` to synthesize
clause-by-clause, overlapped with the LLM stream, so the first audio plays much
sooner: the turn emits a series of `VoiceReplyAudioEvent(isFinal: false)` chunks
followed by a zero-byte `isFinal: true` marker. The player must play the chunks
in order; per-clause synthesis has slightly flatter prosody at the clause joins
than synthesizing the whole reply at once.

```dart
final session = VoiceSession.fromChat(
  recognizer: recognizer, chat: chat, synthesizer: synthesizer,
  streamAudio: true,
);
```

### Tool calling in the voice loop

When the chat has tools, pass `onToolCall` — the turn is driven through core's
`InferenceChat.generateChatResponseWithTools` (run tool → feed the result back →
final answer, capped by `maxToolTurns`, cancelled on barge-in). `onToolCall` is
your tool implementation, exactly as in a text chat; only the final spoken answer
is synthesized.

```dart
final chat = await (await FlutterEdgeAi.getActiveModel(maxTokens: 1024))
    .createChat(tools: myTools, supportsFunctionCalls: true,
                toolChoice: ToolChoice.auto, maxOutputTokens: 128);

final session = VoiceSession.fromChat(
  recognizer: recognizer, chat: chat, synthesizer: synthesizer,
  onToolCall: (call) async => runMyTool(call), // returns the tool result map
);
```

For the full agent (skills / MCP), wrap an `AgentSession` in a `VoiceResponder`
and use `VoiceSession.custom`; `AgentSession.ask(…, isCancelled:)` makes barge-in
halt the agent loop before the next tool.

## Platform support

| Platform | Support |
|---|---|
| Android | ✅ FFI |
| iOS | ✅ FFI |
| macOS | ✅ FFI |
| Windows | ✅ FFI |
| Linux | ✅ FFI |
| Web | 🚧 follow-on (the web arm is a stub that throws `UnsupportedError`) |

On Android, STT (like everything backed by `libLiteRtLm`) is **arm64-only** and
requires **minSdk 30** — see
[Installation → Android architecture](/docs/installation#android-architecture-support).

On Windows, speech needs the litertlm fix from `flutter_gemma_litertlm` 1.7.0, which
every `flutter_edge_ai_litertlm` release has — earlier versions fail with
`CreateTensorBufferFromHostMemory` status 3. See
[Troubleshooting](/docs/troubleshooting#windows-embeddings-and-speech-fail-with-status-3).

## Model support

| Model | Task | Input | Status |
|---|---|---|---|
| **moonshine-tiny** | STT | raw PCM (seq2seq) | ✅ end-to-end |
| **Whisper / Parakeet** | STT | log-mel | ✅ end-to-end |
| **Matcha** | TTS | text (Glow-TTS + CFM) | ✅ end-to-end |
| **Qwen3-TTS** | TTS | text (AR codec-LM, 10 langs + `auto`) | ✅ end-to-end |
| **Inflect-Nano-v2** | TTS | text (VITS, English) | ✅ end-to-end |
| kokoro / supertonic | TTS | text | 🚧 voice follow-on |

Both pipelines are profile-driven (`SttModelProfile` / `TtsModelProfile`), so
adding a new model family is a new profile rather than a new backend.

**Writing this with a coding assistant?** `dart run skills@ get --all` installs [`flutter-edge-ai-speech`](/docs/package-skills), the skill that teaches it STT and TTS model choice, the 16 kHz mono PCM input contract, and the per-transcription output language.
