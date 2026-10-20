// Model provisioning for the Multimodal RAG device suites (not a test file):
// multimodal_rag_demo_test.dart and multimodal_rag_record_test.dart. Call it first in
// a test body (Rule 6b: no setUp).
//
// --dart-define=MULTIMODAL_RAG_EMBEDDER_MODEL=<an EmbeddingModel name> (default
// embeddingGemma2TextVisionAudio740m; embeddingGemma2TextVisionAudio740mSm8850
// on a Snapdragon 8 Elite Gen 5), MULTIMODAL_RAG_EMBEDDER_FILE=<a local copy of
// it> (checked against the catalog's SHA-256) else downloaded;
// MULTIMODAL_RAG_LLM_FILE=<a Gemma 4 .litertlm> else Gemma 4 E2B is downloaded. A
// file outside the catalog (the SM8850 build) also needs
// MULTIMODAL_RAG_LLM_BACKEND / MULTIMODAL_RAG_LLM_MAX_TOKENS (knowledge_app_dependencies
// .dart). No speech-to-text model: nothing is transcribed.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/multimodal_rag/multimodal_rag_app_dependencies.dart'
    show kMultimodalRagLibraryKey;
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/models/model.dart';
import 'package:flutter_edge_ai_example/services/embedding_catalog_install.dart';
import 'package:flutter_edge_ai_example/services/embedding_catalog_provenance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _embedderFile = String.fromEnvironment('MULTIMODAL_RAG_EMBEDDER_FILE');
const _llmFile = String.fromEnvironment('MULTIMODAL_RAG_LLM_FILE');
const _embedderModel = String.fromEnvironment(
  'MULTIMODAL_RAG_EMBEDDER_MODEL',
  defaultValue: 'embeddingGemma2TextVisionAudio740m',
);

final _embedder = catalog.EmbeddingModel.values.byName(_embedderModel);
const _llm = Model.gemma4_E2B_litertlm;

/// Installs the two models the Multimodal RAG screen uses (a no-op once
/// installed), each becoming the active one of its kind, and — when [fresh]
/// — forgets the saved library, so the run starts with nothing indexed.
/// Without [llm] the language model is left as it is.
Future<void> ensureMultimodalRagModels({
  required void Function(String line) log,
  bool llm = true,
  bool fresh = true,
}) async {
  final watch = Stopwatch()..start();
  await bootstrapGemma();

  // EmbeddingGemma 2 (740M): a local copy is accepted only with the pinned
  // bytes, and then recorded as the catalog entry, as an install from the
  // list would be.
  if (_embedderFile.isNotEmpty) {
    final digest = await sha256.bind(File(_embedderFile).openRead()).first;
    expect(
      '$digest',
      _embedder.sha256,
      reason: '$_embedderFile is not the pinned ${_embedder.filename}',
    );
    await FlutterEdgeAi.installEmbedder()
        .modelFromFile(_embedderFile, filename: _embedder.filename)
        .install();
    await persistVerifiedEmbeddingCatalogSelection(
      _embedder,
      spec: EmbeddingModelSpec(
        name: _embedder.filename,
        modelSource: ModelSource.network(_embedder.url),
        modelFilename: _embedder.filename,
      ),
    );
  } else {
    await withCatalogEmbedderSources(
      FlutterEdgeAi.installEmbedder(),
      _embedder,
    ).install();
  }

  // Gemma 4 E2B.
  if (llm) await _installLlm();

  // A fresh library: nothing counted as indexed — the run shows every item
  // being embedded.
  if (fresh) {
    await (await SharedPreferences.getInstance()).remove(
      kMultimodalRagLibraryKey,
    );
  }
  log('models ready in ${watch.elapsedMilliseconds} ms');
}

Future<void> _installLlm() async {
  final llm = FlutterEdgeAi.installModel(
    modelType: _llm.modelType,
    fileType: _llm.fileType,
  );
  if (_llmFile.isNotEmpty) {
    // The catalog knows Gemma 4 E2B by its file name; another file runs on
    // what the MULTIMODAL_RAG_LLM_* defines say.
    llm.fromFile(_llmFile);
  } else {
    llm.fromNetwork(_llm.url);
  }
  await llm.install();
}
