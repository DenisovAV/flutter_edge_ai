import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import '../models/embedding_model.dart' as catalog;
import '../utils/installed_model_lookup.dart';
import 'island_decider_store.dart';
import 'island_voice.dart';
import 'island_voice_recorder.dart';
import 'island_web_gpu.dart';
import 'tiny_island_dependencies.dart';

const _install =
    'Choose EmbeddingGemma 2 Text (270M) on the Embedding Models list (any '
    'EmbeddingGemma 2 bundle works; the 270M is the lightest), then come back.';

/// The app's wiring of the Tiny Island screen: the embedding model the
/// Embedding Models list left active, which must be EmbeddingGemma 2, fitted
/// deciders kept in the app's cache directory (OPFS on the web), and the
/// microphone for spoken requests ([recorder] replaces it: the demo
/// recording hands the screen prepared clips).
TinyIslandDependencies tinyIslandAppDependencies({
  IslandVoiceRecorder Function()? recorder,
}) => TinyIslandDependencies(
  readSetup: readTinyIslandSetup,
  loadEmbedder: (setup) => FlutterEdgeAi.getActiveEmbedder(
    preferredBackend: setup.preferredBackend,
    supportAudio: setup.voiceProblem == null,
  ),
  store: createIslandDeciderStore(),
  recorder: recorder ?? RecordIslandVoiceRecorder.new,
);

/// Which EmbeddingGemma 2 bundle is active, or why this screen cannot run.
Future<TinyIslandSetup> readTinyIslandSetup() async {
  if (kIsWeb) {
    if (await islandWebGpuProblem() case final problem?) {
      return TinyIslandSetupProblem(problem, modelListHelps: false);
    }
  }
  final spec = FlutterEdgeAi.activeEmbedderSpec;
  if (spec == null) {
    return const TinyIslandSetupProblem(
      'No embedding model is active. $_install',
    );
  }
  final profileId = await activeEmbeddingProfileId();
  final files = {for (final file in spec.files) file.filename};
  final model = catalog.EmbeddingModel.values
      .where((m) => m.ragProfileId == profileId && files.contains(m.filename))
      .firstOrNull;
  if (profileId == null || model == null) {
    return const TinyIslandSetupProblem(
      'The active embedding model is not one of the example\'s. $_install',
    );
  }
  if (!model.ragProfileId.startsWith('embeddinggemma2-')) {
    return TinyIslandSetupProblem(
      'Tiny Island decides with EmbeddingGemma 2, and the active model is '
      '${model.displayName}. $_install',
    );
  }
  return TinyIslandEmbedderSetup(
    embedderName: model.displayName,
    model: model.name,
    preferredBackend: model.embedderBackend,
    voiceProblem: _voiceProblem(model),
    voiceThreshold: islandVoiceThresholds[model.name] ?? islandVoiceThreshold,
  );
}

/// Why [model] takes no spoken requests here; null when it does: a bundle
/// with an audio encoder whose voice threshold was measured
/// ([islandVoiceThresholds]), natively.
String? _voiceProblem(catalog.EmbeddingModel model) {
  if (!model.embedsAudio) {
    return 'Speaking needs EmbeddingGemma 2 Text + Vision + Audio (740M), the '
        'bundle with an audio encoder.';
  }
  if (kIsWeb) {
    return 'The voice threshold was measured natively, not on WebGPU: '
        'speaking is off on the web.';
  }
  if (!islandVoiceThresholds.containsKey(model.name)) {
    return 'No voice threshold was measured for this bundle, so speaking is '
        'off with it.';
  }
  return null;
}
