import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import '../models/embedding_model.dart' as catalog;
import '../utils/installed_model_lookup.dart';
import 'embedding_island_decider.dart';
import 'island_vector_cache.dart';
import 'tiny_island_dependencies.dart';

const _install =
    'Choose EmbeddingGemma 2 Text (270M) on the Embedding Models list (any '
    'EmbeddingGemma 2 bundle works; the 270M is the lightest), then come back.';

/// The app's wiring of the Tiny Island screen: the embedding model the
/// Embedding Models list left active, which must be EmbeddingGemma 2, and the
/// Decider over it.
TinyIslandDependencies tinyIslandAppDependencies() => TinyIslandDependencies(
  readSetup: readTinyIslandSetup,
  openDecider:
      (setup, actions, {required onProgress, required isCancelled}) async {
        final embedder = await FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: catalog.embedderBackendForProfile(setup.profileId!),
        );
        debugPrint(
          '[TinyIsland] embedder ${setup.embedderName} on '
          '${embedder.activeBackend?.name ?? 'an unreported backend'}',
        );
        try {
          return await EmbeddingIslandDecider.create(
            model: embedder,
            name: setup.embedderName!,
            profileId: setup.profileId!,
            catalog: actions,
            cache: createIslandVectorCache(),
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
        } catch (_) {
          // The decider owns the model once created; until then it is ours.
          await embedder.close();
          rethrow;
        }
      },
);

/// Which EmbeddingGemma 2 bundle is active, or why this screen cannot run.
Future<TinyIslandSetup> readTinyIslandSetup() async {
  final spec = FlutterEdgeAi.activeEmbedderSpec;
  if (spec == null) {
    return const TinyIslandSetup(
      problem: 'No embedding model is active. $_install',
    );
  }
  final profileId = await activeEmbeddingProfileId();
  final files = {for (final file in spec.files) file.filename};
  final model = catalog.EmbeddingModel.values
      .where((m) => m.ragProfileId == profileId && files.contains(m.filename))
      .firstOrNull;
  if (profileId == null || model == null) {
    return const TinyIslandSetup(
      problem:
          'The active embedding model is not one of the example\'s, so its '
          'embedding space has no name. $_install',
    );
  }
  if (!model.ragProfileId.startsWith('embeddinggemma2-')) {
    return TinyIslandSetup(
      problem:
          'The Decider here is calibrated for EmbeddingGemma 2, and the '
          'active model is ${model.displayName}. $_install',
    );
  }
  return TinyIslandSetup(
    embedderName: model.displayName,
    profileId: model.ragProfileId,
  );
}
