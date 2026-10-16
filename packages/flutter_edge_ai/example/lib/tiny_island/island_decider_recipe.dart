// The Decider API is @experimental; Tiny Island is its demo.
// ignore_for_file: experimental_member_use

import 'dart:convert' show jsonEncode, utf8;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'island_catalog.dart';
import 'island_held_out_requests.dart';

/// Everything a Tiny Island Decider is fitted from: the options, the method,
/// the calibration, and the rows that calibration was built from.
///
/// The [fingerprint] names a stored decider: a change to any of these is a
/// new name, so a decider fitted for an older catalog is never loaded for a
/// newer one.
final class IslandDeciderRecipe {
  IslandDeciderRecipe({
    required List<DeciderOption> options,
    required this.method,
    required this.calibration,
    List<IslandHeldOutRequest> calibrationRows = const [],
  }) : options = List.unmodifiable(options),
       calibrationRows = List.unmodifiable(calibrationRows);

  final List<DeciderOption> options;
  final DeciderMethod method;
  final EmbeddingDeciderCalibration calibration;

  /// The labelled rows behind [calibration] (a `EmbeddingDeciderCalibration` does not
  /// expose them), so the [fingerprint] changes when they do.
  final List<IslandHeldOutRequest> calibrationRows;

  /// What the status line says about the calibration.
  String get calibrationLabel => switch (calibration.kind) {
    'labelled' => 'calibrated on ${calibrationRows.length} held-out requests',
    'crossFit' => 'threshold cross-fitted on its own examples',
    'minSimilarity' => 'fixed threshold ${calibration.threshold}',
    _ => 'never abstains',
  };

  /// A 32-bit FNV-1a of every input above, in hex. The loaded decider is
  /// also checked against the options ([matches]), so a collision cannot
  /// hand back a decider for other actions.
  late final String fingerprint = _fnv1a(
    jsonEncode({
      'v': 1,
      'method': method.name,
      'calibration': calibration.toString(),
      'rows': [
        for (final row in calibrationRows) [row.text, row.actionId],
      ],
      'options': [
        for (final option in options)
          [
            option.id,
            option.description,
            [for (final example in option.examples) example.text],
          ],
      ],
    }),
  );

  /// Whether [decider] (loaded from a stored artifact) has exactly these
  /// options and this calibration's kind of answer.
  bool matches(Decider decider) {
    final loaded = decider.options;
    if (loaded.length != options.length) return false;
    for (var i = 0; i < options.length; i++) {
      final a = options[i];
      final b = loaded[i];
      if (a.id != b.id ||
          a.description != b.description ||
          a.examples.length != b.examples.length) {
        return false;
      }
      for (var j = 0; j < a.examples.length; j++) {
        if (a.examples[j].text != b.examples[j].text) return false;
      }
    }
    return decider.capabilities.calibratedProbabilities ==
        (calibration.kind == 'labelled');
  }

  /// 32-bit FNV-1a over [text]'s UTF-8 bytes. The multiply is done in 16-bit
  /// halves, so it is exact on the web too, where a full product would pass
  /// 2^53.
  static String _fnv1a(String text) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(text)) {
      hash ^= byte;
      final lo = hash & 0xffff;
      final hi = hash >> 16;
      hash =
          (lo * 0x0193 + (((hi * 0x0193 + lo * 0x0100) & 0xffff) << 16)) &
          0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// One Decider option per island action: its id is the action id, and it is
/// the centroid of the action's description and example phrasings (core
/// embeds them with `TaskType.sentenceSimilarity`). The verb and thing ride
/// along as metadata; they are never embedded.
List<DeciderOption> islandDeciderOptions(List<IslandAction> catalog) => [
  for (final action in catalog)
    DeciderOption(
      action.id,
      description: action.description,
      examples: [
        for (final example in action.examples) EmbeddingInput.text(example),
      ],
      metadata: action.metadata,
    ),
];

/// The app's recipe: centroids, calibrated on [islandHeldOutRequests] with
/// core's default error budget (5 % wrong among the answered requests).
///
/// Measured on macOS CPU with EmbeddingGemma 2 Text (270M), 184 actions, 920
/// texts, two folds of the 144 held-out requests plus 30 out-of-scope ones
/// (integration_test/tiny_island_calibration_test.dart): the default
/// cross-fit answers 94 % of in-scope requests, 3 % of those answers wrong.
/// Calibrated on one half of the labelled requests and tested on the other,
/// it answers 99–100 % with 4 % wrong (72 rows put the threshold at 0.877 or
/// 0.866; over both halves 6 of 143 answers wrong); all 144 put it at 0.866.
/// Both refuse all 30 out-of-scope requests. The linear method gives the
/// same answers and adds 15 s to the fit, so the screen keeps centroids.
///
/// The calibration is fitted in the embedding space it runs in — the CPU
/// bundle, a per-SoC NPU bundle and the web's WebGPU each fit their own
/// threshold from their own vectors at the first visit — so no threshold
/// measured on one backend is carried to another.
IslandDeciderRecipe islandDeciderRecipe(List<IslandAction> catalog) =>
    IslandDeciderRecipe(
      options: islandDeciderOptions(catalog),
      method: DeciderMethod.centroid,
      calibration: EmbeddingDeciderCalibration.fromLabelled([
        for (final row in islandHeldOutRequests)
          (input: EmbeddingInput.text(row.text), optionId: row.actionId),
      ]),
      calibrationRows: islandHeldOutRequests,
    );
