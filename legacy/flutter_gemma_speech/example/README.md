# flutter_gemma_speech — agentic voice example

A runnable, on-device **agentic voice loop**: microphone → STT → LLM → TTS →
speaker, entirely on the device. One screen, two modes over the same pipeline:

| Mode | API | What it shows |
|------|-----|---------------|
| **Tools** | `VoiceSession.fromChat(onToolCall:)` | The LLM calls app tools mid-turn (`get_current_time`, `show_alert`); the app runs them and the model speaks the result. Needs only `flutter_gemma_speech` + `flutter_gemma` (core function-calling loop) + the litertlm engine. |
| **Agent** | `VoiceSession.custom(responder: agentVoiceResponder(agent))` | The full `flutter_gemma_agent` drives skills — say *"calculate the hash of hello"* and the bundled calculate-hash JS skill runs, then the answer is spoken. The agent→speech glue (`agent_voice_responder.dart`) lives in the app, so `flutter_gemma_speech` never depends on `flutter_gemma_agent`. |

Speak by **holding the mic button**, or tap **"Demo turn"** to run a bundled
audio clip (no microphone needed).

## Models

- **STT** — Moonshine Tiny (`.tflite`, public download)
- **LLM** — Gemma 4 E2B (`.litertlm`) — loaded from a device-local staged file
  when present, else downloaded from HuggingFace with the token you enter (the
  Gemma repo is gated). Pinned to CPU: the voice path loads Matcha (Metal)
  alongside the LLM, and a concurrent Metal GPU load is flaky on desktop.
- **TTS** — Matcha-TTS (public download)

## Run

```bash
cd packages/flutter_gemma_speech/example
flutter run -d macos      # verified target (see below)
```

Enter a HuggingFace token on the setup screen (or stage
`gemma-4-E2B-it.litertlm` in the app documents directory to run offline), tap
**Download & initialize**, then use the mic or the demo button.

## Platform notes

- **macOS** is wired and verified here (litertlm entitlements + companion-dylib
  staging in `macos/Podfile`, signed with a development team). The voice-loop
  logic itself (both modes) is covered by the on-device integration tests in the
  [`flutter_gemma` example](https://github.com/DenisovAV/flutter_gemma/tree/main/packages/flutter_gemma/example/integration_test).
- **Android** builds a release APK on AGP 9: `minSdk 30` for `.litertlm`, core
  library desugaring for the agent's notifications, and the AGP 9 opt-out in
  `android/gradle.properties`. It has not been run on a device yet.
- **iOS** is scaffolded but needs the same litertlm native setup as the main
  example (memory entitlements, iOS 15 deployment target). Follow the
  [`flutter_gemma` example](https://github.com/DenisovAV/flutter_gemma/tree/main/packages/flutter_gemma/example)
  for the per-platform native configuration.

The full multi-feature app (chat, vision, RAG, STT/TTS screens, voice loop) lives
in the [`flutter_gemma` example](https://github.com/DenisovAV/flutter_gemma/tree/main/packages/flutter_gemma/example);
this one is a focused agentic-voice showcase.
