// What the EmbeddingGemma 2 runtime and its Flutter adapter (the native pass,
// the web pass, describe()) both say: limits, budgets and the refusals with
// one wording. Web-safe: no dart:io, no dart:ffi.

import 'embedder_types.dart';

/// The bundle with an audio encoder.
const liteRtLmAudioBundle = 'embeddinggemma-2-740m';

/// The input length every EmbeddingGemma 2 engine is created with, in tokens.
const liteRtLmMaxInputLength = 1024;

/// The text signatures of the EmbeddingGemma 2 bundles, in tokens: the
/// generic ones have all six, the per-SoC ones 128-1024. The web pins its
/// window against them (the web runtime has no ModelInfo).
const liteRtLmEg2TextSignatures = [128, 256, 512, 1024, 2048, 8192];

/// The vision budget an engine is created with unless the app asks for 70.
const liteRtLmDefaultVisionTokensPerImage = 140;

/// The vision budgets EmbeddingGemma 2 has signatures for.
const liteRtLmVisionTokenBudgets = [140, 70];

/// Why [file] cannot embed audio.
String liteRtLmNoAudioEncoderMessage(String file) =>
    '$file has no audio encoder; install $liteRtLmAudioBundle';

/// Declared images on [file], a bundle without a vision encoder: the same
/// words natively (from ModelInfo's vision signatures) and on the web (from
/// the container header).
String liteRtLmNoVisionEncoderMessage(String file) =>
    '$file has no vision encoder; install embeddinggemma-2-text-vision-440m';

/// Why [file]'s container could not be read to find [looking].
String liteRtLmUnreadableContainerMessage(
  String file,
  String reason, {
  String looking = 'its audio encoder',
}) => 'could not read the container of $file to find $looking: $reason';

/// The runtime's refusal of audio on [file].
EmbedderLoadException liteRtLmNoAudioEncoder(String file) =>
    EmbedderLoadException(liteRtLmNoAudioEncoderMessage(file));

/// The runtime's refusal of a container it could not read.
EmbedderLoadException liteRtLmUnreadableContainer(
  String file,
  String reason,
  Object cause, {
  String looking = 'its audio encoder',
}) => EmbedderLoadException(
  liteRtLmUnreadableContainerMessage(file, reason, looking: looking),
  cause: cause,
);
