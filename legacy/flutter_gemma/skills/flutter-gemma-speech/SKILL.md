---
name: flutter-gemma-speech
description: Use when adding speech to a flutter_gemma app — speech-to-text (transcribe a voice note, dictation, Whisper, moonshine, Parakeet), text-to-speech (Matcha, Qwen3-TTS, Inflect), or a push-to-talk voice assistant with VoiceSession. Also use when transcripts come back in English for non-English audio, a WAV file has to become 16 kHz PCM, synthesized audio plays at the wrong pitch, or getActiveTts throws a StateError about the language. For audio sent straight to Gemma in a chat, use flutter-gemma-inference.
---

# Speech with flutter_gemma_speech

## Rules

1. Depend on `flutter_gemma` and `flutter_gemma_speech`, and import both. The speech package does not re-export core.
2. `transcribe` takes raw PCM — 16 kHz, mono, 16-bit little-endian, as a `Uint8List` — and returns the text. Not a WAV file, not 44.1 or 48 kHz: nothing resamples or converts it.
3. Play synthesized audio at `synth.sampleRate`. It differs per model.
4. Only Whisper has a selectable output language. moonshine-tiny and Parakeet are English-only, and passing a language to them throws `ArgumentError`.
5. STT language: set a default with `getActiveStt(language:)` or override one call with `transcribe(pcm, language:)`. Nothing reloads.
6. TTS language: `close()` the synthesizer first. Asking a live synthesizer for another language throws `StateError`.
7. Android needs `minSdk 30`. There is no web support — the web backends throw `UnsupportedError`.
8. Close recognizers and synthesizers.

## Setup

```sh
flutter pub add flutter_gemma flutter_gemma_speech
```

```dart
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_speech/flutter_gemma_speech.dart';

await FlutterGemma.initialize(
  sttBackends: [LiteRtSttBackend()],
  ttsBackends: [LiteRtTtsBackend()],
);
```

Speech runs on the same native libraries as the `.litertlm` engine. Its build setup — Android `minSdk 30`, the Apple entries — is in the flutter-gemma-inference skill's [platform setup](../flutter-gemma-inference/references/platform-setup.md), installed alongside this one.

## Speech-to-text

An STT model is two files — the model and its tokenizer — usually from different repos. `install()` skips files already on disk.

```dart
await FlutterGemma.installStt()
    .modelFromNetwork('https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_f32.tflite')
    .tokenizerFromNetwork('https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json')
    .ofType(SttModelType.whisper)
    .install();

final SpeechRecognizer recognizer = await FlutterGemma.getActiveStt(language: 'de');
try {
  final String german = await recognizer.transcribe(germanPcm);
  final String french = await recognizer.transcribe(frenchPcm, language: 'fr');
} finally {
  await recognizer.close();
}
```

| `SttModelType` | Languages | Window |
| --- | --- | --- |
| `SttModelType.moonshine` | English | 5 s |
| `SttModelType.whisper` | 99, selectable, default `'en'` | 30 s |
| `SttModelType.parakeet` | English | 5 s; 2.35 GB, so desktop in practice — nothing refuses it on a phone |

**Audio longer than the window is silently truncated**, not rejected: it is zero-padded when shorter and cut when longer, so a 40-second clip on Whisper returns the first 30 seconds with no error. Split long recordings yourself.

Whisper tiny is weak outside English. Whisper base int8 is the next size up in the catalog; install it the same way from `https://huggingface.co/litert-community/whisper-base/resolve/main/whisper_base_30s_i8.tflite` with the tokenizer `https://huggingface.co/openai/whisper-base/resolve/main/tokenizer.json`.

## Getting 16 kHz mono PCM

The package has no resampler and no WAV reader. Record in the right format from the start — with the `record` package:

```dart
import 'package:record/record.dart';

const config = RecordConfig(
  encoder: AudioEncoder.wav,
  sampleRate: 16000,
  numChannels: 1,
);
```

Recording needs microphone access. On Android `record` declares `android.permission.RECORD_AUDIO` in its own manifest and the manifest merger adds it to the app; iOS and macOS need entries of your own:

```xml
<!-- ios/Runner/Info.plist and macos/Runner/Info.plist -->
<key>NSMicrophoneUsageDescription</key>
<string>Speech is transcribed on this device.</string>

<!-- macos/Runner/DebugProfile.entitlements and macos/Runner/Release.entitlements -->
<key>com.apple.security.device.audio-input</key>
<true/>
```

The macOS sandbox withholds the microphone without the entitlement, and it has to be in both entitlements files. On Android, iOS and macOS the user must also allow it at run time; `hasPermission()` asks, so call it before recording:

```dart
final recorder = AudioRecorder();
if (!await recorder.hasPermission()) return;
```

That produces a WAV file. Its header is not always 44 bytes — take the samples from the `data` chunk:

```dart
import 'dart:typed_data';

/// The samples of a 16 kHz mono 16-bit WAV file, without its header.
Uint8List pcmFromWav(Uint8List wav) {
  final view = ByteData.sublistView(wav);
  var offset = 12; // after 'RIFF', the size and 'WAVE'
  while (offset + 8 <= wav.length) {
    final id = String.fromCharCodes(wav, offset, offset + 4);
    final size = view.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    if (id == 'data') {
      final end = start + size > wav.length ? wav.length : start + size;
      return Uint8List.sublistView(wav, start, end);
    }
    offset = start + size + (size & 1); // chunks are padded to an even size
  }
  throw const FormatException('WAV file has no data chunk');
}
```

A file recorded at another rate or channel count — 44.1 kHz stereo, say — has to be converted first: average the channels to mono, then resample with a low-pass filter. Dropping samples instead aliases and costs accuracy.

## Traps

**Transcript comes back in English**
- Symptom: German audio, fluent English text, no error.
- Cause: Whisper's language token decides the output language, not what it understands — with `'en'` it translates. moonshine only ever produces English.
- Fix: use Whisper and pass `language:`.

**A language is rejected**
- Whisper codes are bare and lowercase: `'de'`, not `'de-DE'`, `'DE'` or `'german'`. Malformed codes throw `ArgumentError` from `getActiveStt`.
- A well-formed code the installed checkpoint lacks (e.g. `'zz'`) throws `ArgumentError` from `transcribe`.

## Text-to-speech

```dart
await FlutterGemma.installTts()
    .fromNetwork('https://huggingface.co/litert-community/Matcha-TTS/resolve/main/')
    .ofType(TtsModelType.matcha)
    .install();

final SpeechSynthesizer synth = await FlutterGemma.getActiveTts();
try {
  final audio = await synth.synthesize('Hello world.'); // 16-bit PCM
  final rate = synth.sampleRate;                        // 22050 for Matcha
} finally {
  await synth.close();
}
```

| `TtsModelType` | Languages |
| --- | --- |
| `TtsModelType.matcha` | English, fixed by the installed bundle — it ignores `language:` |
| `TtsModelType.qwen3` | `chinese`, `english`, `german`, `italian`, `portuguese`, `spanish`, `japanese`, `korean`, `french`, `russian`, or `auto` |
| `TtsModelType.inflect` | English |

`TtsModelType.supertonic` and `TtsModelType.kokoro` are in the enum but throw `UnimplementedError` — do not use them.

Switching the Qwen3 language — full lowercase names, not ISO codes, and only with the Qwen3 bundle installed (Matcha still throws the same `StateError` but the language changes nothing):

```dart
final english = await FlutterGemma.getActiveTts(language: 'english');
await english.close();
final german = await FlutterGemma.getActiveTts(language: 'german');
```

Without the `close()`, the second call throws `StateError: Active TTS synthesizer was created for language 'english'; call close() before requesting 'german'.`

## Voice assistant

`VoiceSession` runs one push-to-talk turn: transcribe, generate, speak, with barge-in. It uses the recognizer's current language.

Wrap the loop in `try`/`catch`: a failed stage — transcribe, generate or synthesize — arrives as a **stream error**, not as an event. `VoiceErrorEvent` is reserved in this release and never emitted; the `case` is only there because the switch must be exhaustive. To barge in, call `await voice.interrupt()` — cancelling the subscription is not a portable stop.

```dart
final reply = StringBuffer();
final voice = VoiceSession.fromChat(
  recognizer: await FlutterGemma.getActiveStt(language: 'de'),
  chat: chat,
  synthesizer: await FlutterGemma.getActiveTts(),
);

await for (final event in voice.runTurn(pcm16kMono)) {
  switch (event) {
    case VoiceTranscriptEvent(:final text):
      print('heard: $text');
    case VoiceReplyTextEvent(:final chunk):
      reply.write(chunk);
    case VoiceReplyAudioEvent(:final sampleRate):
      print('audio at $sampleRate Hz');
    case VoiceTurnInterruptedEvent():
      print('interrupted — stop the player');
    case VoiceTurnCompleteEvent():
      print('done');
    case VoiceErrorEvent(:final error):
      print('failed: $error');
  }
}
```

`chat` is an `InferenceChat` from the flutter-gemma-inference skill. A chat created with tools also needs `onToolCall:` — without it `fromChat` throws.
