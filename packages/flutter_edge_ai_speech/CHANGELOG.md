## 0.5.3
- Require `flutter_edge_ai` 2.x.

## 0.5.2
- Renamed from `flutter_gemma_speech`.
- Inflect TTS: speech was garbled — the encoder now gets the blank tokens it was trained with.

## 0.5.1
- Windows: STT/TTS failed with `CreateTensorBufferFromHostMemory` status 3 (needs flutter_gemma_litertlm 1.7.0).

## 0.5.0
- Whisper: output language is a parameter, no longer hardcoded English (#500).

## 0.4.3
- Add VoiceSession(streamAudio:) — clause-by-clause TTS overlapped with the LLM stream for lower time-to-first-audio.

## 0.4.2
- Add Inflect-Nano-v2 — fast on-device TTS (~90× real-time on CPU, English-only).
- VoiceSession.fromChat: optional onToolCall runs function calling in the Voice Loop (via core's generateChatResponseWithTools).

## 0.4.1
- Add Qwen3-TTS (multilingual AR codec-LM, 11 languages) — 2nd selectable TTS family.

## 0.4.0
- feat: on-device Whisper-tiny STT (English-only) — log-mel frontend + GPT-2 BPE decode.
- feat: on-device Parakeet-CTC STT (desktop) — NeMo mel frontend + greedy CTC decode.

## 0.3.0
- Add VoiceSession — on-device push-to-talk voice loop (STT → LLM → TTS) with barge-in.
- feat: robust TTS text frontend — punctuation-as-symbols, numbers/acronyms, neural OOV G2P, clause chunking.
- fix: model-agnostic TTS chunking — word-boundary + duration-aware split so long replies fit MAX_TEXT/MAX_MEL.

## 0.2.0
- Add on-device TTS (Matcha): installTts/getActiveTts, selectable model, PCM output.

## 0.1.0
- feat: on-device STT (moonshine-tiny) via `LiteRtSttBackend` + a generic, selectable `SttModelProfile` pipeline (encode → greedy decode → HF detokenize) on the shared LiteRT engine.
