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
/// options on the NPU, and the web runs them on WebGPU, neither measured.
const islandVoiceThreshold = 0.745;

/// The recipe for spoken requests: the typed recipe's options and method,
/// with [islandVoiceThreshold].
IslandDeciderRecipe islandVoiceDeciderRecipe(List<IslandAction> catalog) =>
    IslandDeciderRecipe(
      options: islandDeciderOptions(catalog),
      method: DeciderMethod.centroid,
      calibration: const DeciderCalibration.minSimilarity(islandVoiceThreshold),
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
