import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_gemma/core/domain/model_source.dart' show ModelSource;
import 'package:flutter_gemma/core/model.dart' show ModelFileType, ModelType;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;

/// Ready-made [InferenceModelSpec]s for the OS built-in models.
///
/// These specs carry an *inert* bundled source: the built-in engine never
/// downloads or reads a file — the OS owns the weights — so the source is only
/// an identity token. All are `fileType: ModelFileType.builtIn`, which is what
/// `BuiltInAiEngine.canHandle` matches on and what makes core's install
/// pipeline skip the (nonexistent) file.
///
/// Which spec to install is a platform question, so prefer
/// [forCurrentPlatform] over hardcoding one.
abstract final class BuiltInAiModels {
  /// Gemini Nano via Android ML Kit GenAI (AICore). `name: 'gemini-nano'`.
  static InferenceModelSpec get geminiNano => InferenceModelSpec(
    name: 'gemini-nano',
    modelSource: ModelSource.bundled('gemini-nano'),
    modelType: ModelType.general,
    fileType: ModelFileType.builtIn,
  );

  /// Apple Foundation Models (iOS/macOS). `name: 'apple-foundation-models'`.
  static InferenceModelSpec get appleFoundationModels => InferenceModelSpec(
    name: 'apple-foundation-models',
    modelSource: ModelSource.bundled('apple-foundation-models'),
    modelType: ModelType.general,
    fileType: ModelFileType.builtIn,
  );

  /// Windows AI Foundry (Phi Silica). `name: 'windows-ai-foundry'`.
  static InferenceModelSpec get windowsAiFoundry => InferenceModelSpec(
    name: 'windows-ai-foundry',
    modelSource: ModelSource.bundled('windows-ai-foundry'),
    modelType: ModelType.general,
    fileType: ModelFileType.builtIn,
  );

  /// Gemini Nano via the Chrome Prompt API (desktop Chrome / Chromium-Edge).
  /// `name: 'chrome-prompt-api'`.
  static InferenceModelSpec get chromePromptApi => InferenceModelSpec(
    name: 'chrome-prompt-api',
    modelSource: ModelSource.bundled('chrome-prompt-api'),
    modelType: ModelType.general,
    fileType: ModelFileType.builtIn,
  );

  /// Every built-in spec, for apps that build their own model list.
  static List<InferenceModelSpec> get all => [
    geminiNano,
    appleFoundationModels,
    windowsAiFoundry,
    chromePromptApi,
  ];

  /// The spec for the platform this app is running on.
  ///
  /// Null on Linux and Fuchsia — neither has a built-in OS model — so callers
  /// fall back to a downloaded model instead of installing a spec nothing can
  /// run. This answers identity only; whether the model is usable on *this
  /// device* is the separate runtime question `BuiltInAi.availability()` asks.
  static InferenceModelSpec? get forCurrentPlatform {
    if (kIsWeb) return chromePromptApi;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => geminiNano,
      TargetPlatform.iOS || TargetPlatform.macOS => appleFoundationModels,
      TargetPlatform.windows => windowsAiFoundry,
      TargetPlatform.linux || TargetPlatform.fuchsia => null,
    };
  }
}
