// Shared by the Tiny Island device tests: which EmbeddingGemma 2 bundle to
// run, and installing it as the Embedding Models list would.
//
//   --dart-define=TINY_ISLAND_EMBEDDER_MODEL=<catalog entry name>
//       default embeddingGemma2Text270m (the CPU bundle). A per-SoC NPU
//       bundle (e.g. embeddingGemma2Text270mSm8850 on a Galaxy S26+) runs on
//       the NPU, and the screen test then requires backend npu.
//   --dart-define=TINY_ISLAND_EMBEDDER_FILE=<a local copy of that bundle>
//       checked against the catalog's SHA-256; on macOS it must sit inside
//       the app's container, e.g. ~/Library/Containers/
//       dev.flutterberlin.flutterGemmaExample55/Data/eg2_local/. Unset: the
//       bundle is downloaded (ungated).

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/services/embedding_catalog_install.dart';
import 'package:flutter_edge_ai_example/services/embedding_catalog_provenance.dart';
import 'package:flutter_test/flutter_test.dart';

const _modelName = String.fromEnvironment(
  'TINY_ISLAND_EMBEDDER_MODEL',
  defaultValue: 'embeddingGemma2Text270m',
);
const _embedderFile = String.fromEnvironment('TINY_ISLAND_EMBEDDER_FILE');

/// The catalog entry [TINY_ISLAND_EMBEDDER_MODEL] names; fails the test for
/// a name that is not an EmbeddingGemma 2 entry.
catalog.EmbeddingModel tinyIslandEmbedder() {
  final model = catalog.EmbeddingModel.values
      .where((m) => m.name == _modelName)
      .firstOrNull;
  if (model == null || !model.ragProfileId.startsWith('embeddinggemma2-')) {
    fail(
      'TINY_ISLAND_EMBEDDER_MODEL=$_modelName is not an EmbeddingGemma 2 '
      'entry of the example catalog',
    );
  }
  return model;
}

/// Whether the bundle under test is a per-SoC NPU bundle (it runs nowhere
/// else, so the Decider's embedder must report the NPU).
bool tinyIslandExpectsNpu() =>
    tinyIslandEmbedder().embedderBackend == PreferredBackend.npu;

/// Installs the bundle and records it as the catalog's selection, as an
/// install from the Embedding Models list would. Call it first in a test
/// body (no setUp: Rule 6b).
Future<catalog.EmbeddingModel> ensureTinyIslandEmbedder() async {
  final model = tinyIslandEmbedder();
  await installTinyIslandEmbedder(model, localFile: _embedderFile);
  return model;
}

/// Installs [model] and records it as the catalog's selection, as
/// [ensureTinyIslandEmbedder] does for the bundle the defines name: from
/// [localFile] (checked against the catalog's SHA-256) when it is not empty,
/// else from the network.
Future<void> installTinyIslandEmbedder(
  catalog.EmbeddingModel model, {
  String localFile = '',
}) async {
  await bootstrapGemma();
  if (localFile.isNotEmpty) {
    final digest = await sha256.bind(File(localFile).openRead()).first;
    expect(
      '$digest',
      model.sha256,
      reason: '$localFile is not the pinned ${model.filename}',
    );
    await FlutterEdgeAi.installEmbedder()
        .modelFromFile(localFile, filename: model.filename)
        .install();
    await persistVerifiedEmbeddingCatalogSelection(
      model,
      spec: EmbeddingModelSpec(
        name: model.filename,
        modelSource: ModelSource.network(model.url),
        modelFilename: model.filename,
      ),
    );
  } else {
    await withCatalogEmbedderSources(
      FlutterEdgeAi.installEmbedder(),
      model,
    ).install();
  }
}
