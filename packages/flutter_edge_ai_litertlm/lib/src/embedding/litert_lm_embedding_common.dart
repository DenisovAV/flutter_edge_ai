// What both `.litertlm` embedding passes share — the native one over
// LiteRT-LM's C API and the web one over `@litert-lm/core`'s EmbeddingEngine:
// the engine tag, the input cap, the image and audio containers, and the web's
// audio refusal.
// Web-safe: imports only core's engine library, so the web arm of
// `LiteRtEmbeddingBackend` can use it without pulling dart:ffi.

import 'package:flutter_edge_ai/engine.dart';

/// The engine's name in messages and errors, native and web alike: the same
/// LiteRT-LM runtime, compiled to WebAssembly on the web.
const liteRtLmEngineTag = 'LiteRT-LM';

/// The web's answer to declared audio, from `describe()` and from the web
/// pass. Native platforms embed audio from 1.13.1 (on a bundle with an audio
/// encoder); the web pass does not take audio parts.
const liteRtLmNoAudioRefusal =
    'flutter_edge_ai_litertlm embeds EmbeddingGemma 2 audio on native '
    'platforms (from 1.13.1); on the web it embeds text and images only';

/// The explicit text input cap (D21), on every platform. Never raised on
/// mobile; on the web it is also the runtime's own default, which keeps the
/// engine inside the 4 GB wasm32 address space.
const liteRtLmMaxInputLength = 1024;

/// The image containers LiteRT-LM's stb decoder handles, as measured on our
/// native-v0.18.0-d dylib (X3): PNG, JPEG, GIF and BMP decode; WebP, TIFF
/// and garbage fail with code 3; stb has no HEIC decoder. Reported at load, so
/// core refuses every other container on the caller's isolate, before the
/// request is sent.
///
/// The web runtime is the same C++ compiled to WebAssembly; its MIME list also
/// names PSD, HDR, PGM/PPM and TGA, but those were never measured and core's
/// sniffer does not recognise them, so the web pass reports this same set.
final liteRtLmImageFormats = Set<EncodedMediaFormat>.unmodifiable({
  EncodedMediaFormat.jpeg,
  EncodedMediaFormat.png,
  EncodedMediaFormat.gif,
  EncodedMediaFormat.bmp,
});

/// The audio containers LiteRT-LM decodes, natively: miniaudio reads WAV, MP3
/// and FLAC, mixes down to mono and resamples to 16 kHz (upstream
/// `audio_preprocessor_miniaudio.cc`; measured on the 740m through our
/// macOS build: FLAC gives the WAV's vector, a 44.1 kHz stereo WAV of the same
/// speech cos 0.96 to the 16 kHz mono one and a 48 kbit/s MP3 0.95 — the audio
/// encoder's int8 activations amplify any small change). Ogg and M4A fail to
/// open in miniaudio (status 2), so they are left out and core refuses them on
/// the caller's isolate.
final liteRtLmAudioFormats = Set<EncodedMediaFormat>.unmodifiable({
  EncodedMediaFormat.wav,
  EncodedMediaFormat.mp3,
  EncodedMediaFormat.flac,
});

/// What the web arm says to `npu` for a `.litertlm` bundle: the NPU runs
/// EmbeddingGemma 2 only through the native Qualcomm dispatch.
const liteRtLmWebNpuRefusal =
    'EmbeddingGemma 2 runs on the NPU on Qualcomm Android and Qualcomm Linux '
    'arm64 only, not on the web. Omit preferredBackend here.';
