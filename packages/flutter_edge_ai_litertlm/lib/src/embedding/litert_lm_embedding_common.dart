// What both `.litertlm` embedding passes share — the native one over
// LiteRT-LM's C API and the web one over `@litert-lm/core`'s EmbeddingEngine:
// the engine tag, the input cap, the image and audio containers, and the
// refusal of audio on a bundle without an audio encoder.
// Web-safe: imports only core's engine library and the pure-Dart vendor table
// (npu_stacks.dart), so the web arm of `LiteRtEmbeddingBackend` can use it
// without pulling dart:ffi.

import 'package:flutter_edge_ai/engine.dart';

import 'package:litertlm_dart/internal.dart' hide ActivationDataType;

export 'package:litertlm_dart/internal.dart'
    show liteRtLmAudioBundle, liteRtLmMaxInputLength;

/// The engine's name in messages and errors, native and web alike: the same
/// LiteRT-LM runtime, compiled to WebAssembly on the web.
const liteRtLmEngineTag = 'LiteRT-LM';

/// Declared audio on [file], a bundle whose container has no audio encoder
/// (D23: read from the container, never from ModelInfo, which claims audio on
/// the 270m and the 440m). The same words natively and on the web.
EmbeddingLoadException liteRtLmNoAudioEncoder(String file) =>
    EmbeddingLoadException(
      liteRtLmNoAudioEncoderMessage(file),
      engine: liteRtLmEngineTag,
    );

/// The container of [file] could not be read to find [looking] (its audio
/// encoder, unless said otherwise): a load failure, never "no audio".
EmbeddingLoadException liteRtLmUnreadableContainer(
  String file,
  String reason,
  Object cause, {
  String looking = 'its audio encoder',
}) => EmbeddingLoadException(
  liteRtLmUnreadableContainerMessage(file, reason, looking: looking),
  engine: liteRtLmEngineTag,
  cause: cause,
);

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

/// The audio containers LiteRT-LM decodes, natively and on the web (the same
/// C++ compiled to WebAssembly, whose `SUPPORTED_AUDIO_MIME_TYPES` in
/// `@litert-lm/core` 0.18.0 are WAV, MP3 and FLAC too): miniaudio reads WAV,
/// MP3 and FLAC, mixes down to mono and resamples to 16 kHz (upstream
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
/// EmbeddingGemma 2 only through a native dispatch ([NpuStack]).
final liteRtLmWebNpuRefusal =
    'EmbeddingGemma 2 runs on the NPU ${liteRtLmEmbeddingNpuHosts()}, not on '
    'the web. Omit preferredBackend here.';

/// Where EmbeddingGemma 2 runs on an NPU, for a sentence: `on <vendor's
/// hosts>, and on <…>, only`.
String liteRtLmEmbeddingNpuHosts() =>
    'on ${NpuStack.values.map(_embeddingNpuHosts).join(', and on ')}, only';

String _embeddingNpuHosts(NpuStack vendor) => switch (vendor) {
  NpuStack.qualcomm => 'Qualcomm Android and Qualcomm Linux arm64',
  NpuStack.googleTensor => 'Google Tensor G5/G6 Android devices',
  NpuStack.mediatek => 'MediaTek Dimensity Android devices',
  NpuStack.intel => 'Intel NPUs with Windows x64',
};
