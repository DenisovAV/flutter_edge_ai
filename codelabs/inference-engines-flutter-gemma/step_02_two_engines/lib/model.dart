import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_builtin_ai/flutter_edge_ai_builtin_ai.dart';

/// One model this app can run — either a file it downloads, or the model the
/// OS already ships.
///
/// The two differ in where the weights come from and nothing else: the same
/// [id] / [modelType] / [fileType] triple drives install, activation and chat.
class ModelChoice {
  const ModelChoice({
    required this.label,
    required this.id,
    required this.modelType,
    required this.fileType,
    this.url,
    this.sizeLabel = '',
    this.requiresToken = false,
  });

  final String label;

  /// How this app names the model. For a downloaded model it is the file name,
  /// which is also what `FlutterEdgeAi.isModelInstalled` is keyed by. For a
  /// built-in one it is the OS model's name — and nothing is keyed by it,
  /// because there is no file and no install record.
  final String id;

  /// What the model IS — the engine bakes in the chat template;
  /// modelType instead drives thinking-tag stripping & tool parsing.
  final ModelType modelType;

  /// Which engine opens it. `.litertlm` → LiteRtLmEngine, `.builtIn` →
  /// BuiltInAiEngine. This field is the whole "engine switch".
  final ModelFileType fileType;

  /// Where the bytes are. `null` for a built-in model — there is no file.
  final String? url;

  final String sizeLabel;

  /// Hugging Face serves this repo behind a licence gate; run with
  /// `--dart-define=HF_TOKEN=hf_...`.
  final bool requiresToken;

  bool get isBuiltIn => fileType == ModelFileType.builtIn;
}

abstract final class Models {
  /// The plugin's namesake, run by the LiteRT-LM engine from a downloaded file.
  static const gemma3 = ModelChoice(
    label: 'Gemma 3 1B',
    id: 'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
    url:
        'https://huggingface.co/litert-community/Gemma3-1B-IT/resolve/main/'
        'Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    sizeLabel: '0.6 GB',
    requiresToken: true,
  );

  /// Ungated, so no Hugging Face token. The largest of the downloadable
  /// models: 2.59 GB, and a phone with 6 GB of RAM or more.
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    id: 'gemma-4-E2B-it.litertlm',
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    sizeLabel: '2.59 GB',
  );

  /// The web build. The browser engine (`@litert-lm/core`) runs only models
  /// exported for it — [gemma3] and the native [gemma4] install fine on web and
  /// then fail when the engine starts — and this is the web export of the
  /// same Gemma 4 E2B, the smallest one published.
  static const gemma4Web = ModelChoice(
    label: 'Gemma 4 E2B (web build)',
    id: 'gemma-4-E2B-it-web.litertlm',
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    sizeLabel: '2.0 GB',
  );

  /// The model the app downloads when it is not running the built-in engine.
  /// Native platforms get [gemma3]; the browser engine only runs a
  /// `.litertlm` file built for it, and [gemma4Web] is the only one
  /// published, so on web the fallback is fixed.
  static ModelChoice get downloaded => kIsWeb ? gemma4Web : gemma3;

  /// The downloadable models to offer in the chat's switch-model menu. On
  /// web the native files — [gemma3], [gemma4] — install and then fail at
  /// engine creation; only [gemma4Web] runs there, so offer only that.
  static List<ModelChoice> get downloadable =>
      kIsWeb ? [gemma4Web] : [gemma3, gemma4];

  /// The model the platform ships: Gemini Nano on Android and in Chrome, Apple
  /// Foundation Models on iOS and macOS. Nothing to download — the OS or the
  /// browser owns the weights, so [url] is null and [sizeLabel] says so.
  ///
  /// A getter, not a const: the ready-made specs are chosen per platform.
  /// This codelab leaves out the package's Windows AI Foundry spec, and Linux
  /// has no OS built-in model, so on both this throws rather than quietly
  /// offering a model the sample did not configure.
  static ModelChoice get builtIn {
    // `kIsWeb` is asked BEFORE `defaultTargetPlatform`, which on the web
    // reports the host OS — a Chrome on a Mac would otherwise be handed the
    // Apple Foundation Models arm, which only a native app can reach.
    final (spec, label) = kIsWeb
        ? (BuiltInAiModels.chromePromptApi, 'Gemini Nano (Chrome)')
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => (
              BuiltInAiModels.geminiNano,
              'Gemini Nano',
            ),
            TargetPlatform.iOS || TargetPlatform.macOS => (
              BuiltInAiModels.appleFoundationModels,
              'Apple Foundation Models',
            ),
            _ => throw UnsupportedError(
              'No built-in AI model on $defaultTargetPlatform',
            ),
          };
    return ModelChoice(
      label: label,
      id: spec.name,
      modelType: spec.modelType,
      fileType: ModelFileType.builtIn,
      sizeLabel: 'already on the device',
    );
  }
}
