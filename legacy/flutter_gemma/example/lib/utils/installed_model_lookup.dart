import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/models/embedding_model.dart'
    as example_embedding;
import 'package:flutter_gemma_example/models/model.dart';
import 'package:flutter_gemma_example/models/translate_model.dart';

/// Resolves the on-disk path (or web URL) for an installed model file.
Future<String> resolveInstalledModelPath(String installedId) async {
  final registry = ServiceRegistry.instance;
  final info = await registry.modelRepository.loadModel(installedId);
  final source = info?.source;
  if (source != null) {
    switch (source) {
      case FileSource(:final path):
        return path;
      case NetworkSource(:final url) when kIsWeb:
        return url;
      case AssetSource(:final path) when kIsWeb:
        return path;
      case BundledSource(:final resourceName):
        return registry.fileSystemService.getBundledResourcePath(resourceName);
      case NetworkSource():
      case AssetSource():
        break;
    }
  }
  return registry.fileSystemService.getReadTargetPath(installedId);
}

bool isInferenceOrTranslationArtifact(String id) {
  final lower = id.toLowerCase();
  return lower.endsWith('.task') ||
      lower.endsWith('.bin') ||
      lower.endsWith('.litertlm');
}

bool isEmbeddingArtifact(String id) {
  final lower = id.toLowerCase();
  return lower.endsWith('.tflite') || lower.endsWith('.model');
}

bool isDownloadedModelArtifact(String id) {
  return isInferenceOrTranslationArtifact(id) || isEmbeddingArtifact(id);
}

bool isLoadableArtifact(String id) {
  final lower = id.toLowerCase();
  return isInferenceOrTranslationArtifact(id) || lower.endsWith('.tflite');
}

/// Whether any inference, translation, or embedding model files are installed.
Future<bool> hasDownloadedModels() async {
  final installed = await FlutterGemma.listInstalledModels();
  return installed.any(isDownloadedModelArtifact);
}

String? _inferenceModelFilenameFromSpec(InferenceModelSpec spec) {
  final files = spec.files;
  if (files.isEmpty) return null;

  for (final file in files) {
    if (file.isRequired) return file.filename;
  }
  // Legacy/corrupt specs with no required entry: avoid LoRA-only identity.
  return files.first.filename;
}

String? _embeddingModelFilenameFromSpec(EmbeddingModelSpec spec) {
  final files = spec.files;
  if (files.isEmpty) return null;

  for (final file in files) {
    if (file.filename.toLowerCase().endsWith('.tflite')) {
      return file.filename;
    }
  }
  // Non-.tflite model weights (exclude tokenizer sidecar files).
  for (final file in files) {
    final lower = file.filename.toLowerCase();
    if (lower.endsWith('.model') || lower.endsWith('.json')) continue;
    return file.filename;
  }
  return null;
}

String? activeInferenceModelId() {
  if (!FlutterGemma.hasActiveModel()) return null;
  final spec = FlutterGemmaPlugin.instance.modelManager.activeInferenceModel;
  if (spec is! InferenceModelSpec) return null;
  return _inferenceModelFilenameFromSpec(spec);
}

String? activeEmbeddingModelId() {
  if (!FlutterGemma.hasActiveEmbedder()) return null;
  final spec = FlutterGemmaPlugin.instance.modelManager.activeEmbeddingModel;
  if (spec is! EmbeddingModelSpec) return null;
  return _embeddingModelFilenameFromSpec(spec);
}

/// Filenames marked active in the plugin (inference + embedding).
Set<String> activeModelIds() {
  final ids = <String>{};
  final inferenceId = activeInferenceModelId();
  if (inferenceId != null) {
    ids.add(inferenceId);
  }
  if (FlutterGemma.hasActiveEmbedder()) {
    final spec = FlutterGemmaPlugin.instance.modelManager.activeEmbeddingModel;
    if (spec is EmbeddingModelSpec) {
      for (final file in spec.files) {
        ids.add(file.filename);
      }
    }
  }
  return ids;
}

Set<String> loadedModelIds() {
  final ids = <String>{};
  final plugin = FlutterGemmaPlugin.instance;

  if (plugin.initializedModel != null) {
    final inferenceId = activeInferenceModelId();
    if (inferenceId != null) {
      ids.add(inferenceId);
    }
  }

  if (plugin.initializedEmbeddingModel != null) {
    final embeddingId = activeEmbeddingModelId();
    if (embeddingId != null) {
      ids.add(embeddingId);
    }
  }

  return ids;
}

sealed class DownloadedCatalogMatch {
  const DownloadedCatalogMatch();

  String get displayName;
}

final class InferenceMatch extends DownloadedCatalogMatch {
  const InferenceMatch(this.model);

  final Model model;

  @override
  String get displayName => model.displayName;
}

final class TranslationMatch extends DownloadedCatalogMatch {
  const TranslationMatch(this.model);

  final TranslateModel model;

  @override
  String get displayName => model.displayName;
}

final class EmbeddingMatch extends DownloadedCatalogMatch {
  const EmbeddingMatch({required this.model, required this.isTokenizer});

  final example_embedding.EmbeddingModel model;
  final bool isTokenizer;

  @override
  String get displayName =>
      isTokenizer ? '${model.displayName} (tokenizer)' : model.displayName;
}

String? _urlLastSegment(String url) {
  if (url.isEmpty) return null;
  final segments = Uri.parse(url).pathSegments;
  return segments.isNotEmpty ? segments.last : null;
}

bool _matchesInstalledId(
  String installedId, {
  required String filename,
  required String url,
  String? webUrl,
  String? desktopUrl,
}) {
  if (installedId == filename) return true;
  if (_urlLastSegment(url) == installedId) return true;
  final web = webUrl;
  if (web != null && web.isNotEmpty && _urlLastSegment(web) == installedId) {
    return true;
  }
  final desktop = desktopUrl;
  if (desktop != null &&
      desktop.isNotEmpty &&
      _urlLastSegment(desktop) == installedId) {
    return true;
  }
  return false;
}

DownloadedCatalogMatch? resolveCatalog(String installedId) {
  for (final model in Model.values) {
    if (_matchesInstalledId(
      installedId,
      filename: model.filename,
      url: model.url,
      webUrl: model.webUrl,
      desktopUrl: model.desktopUrl,
    )) {
      return InferenceMatch(model);
    }
  }

  for (final model in TranslateModel.values) {
    if (_matchesInstalledId(
      installedId,
      filename: model.filename,
      url: model.url,
    )) {
      return TranslationMatch(model);
    }
  }

  for (final model in example_embedding.EmbeddingModel.values) {
    if (_matchesInstalledId(
      installedId,
      filename: model.filename,
      url: model.url,
    )) {
      return EmbeddingMatch(model: model, isTokenizer: false);
    }
    if (_matchesInstalledId(
      installedId,
      filename: model.tokenizerFilename,
      url: model.tokenizerUrl,
    )) {
      return EmbeddingMatch(model: model, isTokenizer: true);
    }
  }

  return null;
}

/// True if [tokenizerFilename] should stay installed after removing [removedModelFilename].
Future<bool> isEmbeddingTokenizerStillNeeded({
  required String tokenizerFilename,
  required String removedModelFilename,
}) async {
  final installed = await FlutterGemma.listInstalledModels();
  for (final model in example_embedding.EmbeddingModel.values) {
    if (model.tokenizerFilename != tokenizerFilename) continue;
    if (model.filename == removedModelFilename) continue;
    if (installed.contains(model.filename)) return true;
  }
  return false;
}

/// Whether uninstalling [installedId] clears the active embedding identity.
bool isActiveEmbeddingArtifact(String installedId) {
  if (!FlutterGemma.hasActiveEmbedder()) return false;
  final spec = FlutterGemmaPlugin.instance.modelManager.activeEmbeddingModel;
  if (spec is! EmbeddingModelSpec) return false;
  return spec.files.any((file) => file.filename == installedId);
}
