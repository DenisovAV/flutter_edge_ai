// The Decider API is @experimental; Tiny Island is its demo.
// ignore_for_file: experimental_member_use

import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import '../utils/audio_converter.dart';
import 'island_catalog.dart';
import 'island_decider_recipe.dart';

/// The cosine a spoken request needs to reach an action.
///
/// Spoken requests are embedded as plain audio (EmbeddingGemma 2 740M has an
/// audio encoder; nothing is transcribed) and compared with the same option
/// centroids as typed ones. Their cosines are lower — the typed threshold is
/// 0.866 — so spoken requests get a decider of their own with this fixed
/// threshold.
///
/// Measured on macOS CPU with the 740M CPU bundle: 426 spoken held-out
/// requests (141 English by three macOS voices, 3 German) and 86 spoken
/// out-of-scope ones, synthetic speech from `say`. At 0.745, 51 % of the
/// requests are answered, 4.6 % of those wrong, and every out-of-scope one is
/// refused (the closest reaches 0.69). A human voice was not measured. The
/// value holds for that bundle and backend only: an NPU bundle embeds the
/// options on the NPU (its own value below), and the web runs them on WebGPU,
/// not measured.
const islandVoiceThreshold = 0.745;

/// The same for the per-SoC bundle of the Galaxy S26+ (SM8850): the options
/// are embedded on the NPU, the audio on the CPU, and the cosines come out
/// lower and closer together. Measured on a DDP Galaxy S26+ with the same 426
/// and 86 clips: 74.4 % of the held-out ones rank their action first, and at
/// 0.657 (the same 5 % error rule) only 15 % are answered, 4.7 % of those
/// wrong; every out-of-scope clip is refused. A 10 % budget (0.569) would
/// answer 48 %.
const islandVoiceThresholdSm8850 = 0.657;

/// The voice threshold of each bundle it was measured on, by catalog name.
/// Speaking is off with any other.
const islandVoiceThresholds = {
  'embeddingGemma2TextVisionAudio740m': islandVoiceThreshold,
  'embeddingGemma2TextVisionAudio740mSm8850': islandVoiceThresholdSm8850,
};

/// The recipe for spoken requests: the typed recipe's options and method,
/// with a fixed [threshold] (the bundle's from [islandVoiceThresholds]).
IslandDeciderRecipe islandVoiceDeciderRecipe(
  List<IslandAction> catalog, {
  double threshold = islandVoiceThreshold,
}) => IslandDeciderRecipe(
  options: islandDeciderOptions(catalog),
  method: DeciderMethod.centroid,
  calibration: DeciderCalibration.minSimilarity(threshold),
);

/// How long the WAV recording [wav] plays.
Duration islandWavDuration(Uint8List wav) {
  final parsed = AudioConverter.parseWav(wav);
  return AudioConverter.calculateDuration(
    parsed.pcmData,
    sampleRate: parsed.sampleRate,
    channels: parsed.channels,
  );
}
