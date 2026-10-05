import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// A model Motormind offers. Mirrors the upstream example catalog for the
/// entries we ship, with the project's own device-fit and role fields.
///
/// Both current entries are `.litertlm` bundles from the public
/// `litert-community` Hugging Face organization, which is **not gated**: no
/// token is required. (The `google/gemma-4-E2B` repo is the raw training
/// checkpoint and is not usable here.) A token field remains for mirrors or
/// future gated entries.
class AdvisorModelSpec {
  const AdvisorModelSpec({
    required this.id,
    required this.displayName,
    required this.description,
    required this.url,
    required this.filename,
    required this.sizeBytes,
    required this.minFreeRamMb,
    required this.modelType,
    required this.preferredBackend,
    this.fileType = ModelFileType.litertlm,
    this.needsToken = false,
    this.supportsTools = true,
    this.isThinking = false,
    this.maxTokens = 4096,
    this.temperature = 0.8,
    this.topK = 40,
    this.topP = 0.95,
  });

  final String id;
  final String displayName;
  final String description;
  final String url;
  final String filename;
  final int sizeBytes;
  final int minFreeRamMb;
  final ModelType modelType;
  final ModelFileType fileType;
  final PreferredBackend preferredBackend;
  final bool needsToken;
  final bool supportsTools;
  final bool isThinking;
  final int maxTokens;
  final double temperature;
  final int topK;
  final double topP;

  String get sizeLabel => '${(sizeBytes / 1e9).toStringAsFixed(sizeBytes >= 1e9 ? 1 : 2)} GB';
}

abstract final class ModelCatalog {
  /// Default. Best extraction and narration of the small set; native tool
  /// calls on LiteRT-LM; needs roughly 4 GB free RAM.
  static const gemma4E2B = AdvisorModelSpec(
    id: 'gemma-4-e2b-it',
    displayName: 'Gemma 4 E2B',
    description: 'Best quality. About 2.6 GB download; needs a recent phone with 4 GB free.',
    url: 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    filename: 'gemma-4-E2B-it.litertlm',
    sizeBytes: 2590000000,
    minFreeRamMb: 4000,
    modelType: ModelType.gemma4,
    preferredBackend: PreferredBackend.gpu,
    isThinking: true,
    temperature: 1.0,
    topK: 64,
  );

  /// Light option and the fallback for older devices.
  static const qwen3_0_6B = AdvisorModelSpec(
    id: 'qwen3-0.6b',
    displayName: 'Qwen3 0.6B',
    description: 'Light and fast. About 0.6 GB; runs on most phones. Weaker on messy sentences.',
    url: 'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
    filename: 'Qwen3-0.6B.litertlm',
    sizeBytes: 610000000,
    minFreeRamMb: 1500,
    modelType: ModelType.qwen3,
    preferredBackend: PreferredBackend.cpu,
    isThinking: true,
    temperature: 0.7,
  );

  static const List<AdvisorModelSpec> all = [gemma4E2B, qwen3_0_6B];
  static const AdvisorModelSpec defaultModel = gemma4E2B;

  static AdvisorModelSpec? byId(String id) => all.where((m) => m.id == id).firstOrNull;
}
