import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver;
import 'package:flutter_gemma/core/registry/hugging_face_resolver_source.dart'
    show HuggingFaceResolverSource;
import 'package:flutter_gemma/core/registry/inference_engine_provider.dart'
    show InferenceEngineProvider;
import 'package:flutter_gemma/core/registry/runtime_config.dart'
    show RuntimeConfig;
import 'package:flutter_gemma/flutter_gemma_interface.dart' show InferenceModel;
import 'package:flutter_local_ai/flutter_local_ai.dart' show LocalAiModel;

import 'availability.dart' show BuiltInAi;
import 'availability_types.dart';
import 'builtin_ai_hugging_face_resolver.dart'
    show BuiltInAiHuggingFaceResolver;
import 'builtin_ai_model.dart' show BuiltInAiModel;

/// Built-in OS AI engine (Gemini Nano via ML Kit GenAI on Android; Apple
/// Foundation Models on iOS/macOS; Windows AI Foundry; the Chrome Prompt API
/// on web), backed by flutter_local_ai.
///
/// Register it at startup alongside whatever other engines the app uses:
///
/// ```dart
/// await FlutterGemma.initialize(
///   inferenceEngines: const [BuiltInAiEngine()],
/// );
/// ```
///
/// A pure factory: it verifies the OS model is ready, asks flutter_local_ai to
/// load it, and hands back a bare [BuiltInAiModel]. Core owns the singleton
/// lifecycle through [InferenceModel.addCloseListener].
///
/// **Every unsupported [RuntimeConfig] knob fails here, at creation.** Audio
/// input and LoRA ranks are things no built-in OS model can do on any device,
/// so [createModel] rejects them outright. `supportImage: true` on a backend
/// with no vision path (Apple 26, Windows, the Prompt API) throws
/// `LocalAiUnsupportedException` out of `LocalAiModel.create`, which probes the
/// backend before loading.
///
/// That last one is a **behaviour change from 0.2.x**, which accepted the flag
/// and only failed later, when an image was actually added. Letting it through
/// is worse than breaking: it hands back a model that silently is not the one
/// that was asked for, and the mismatch then surfaces deep in a chat turn
/// instead of at the call that got it wrong. Gate on
/// `LocalAi.capabilities().supportsVision` (or drop the flag) where the backend
/// may not have vision.
class BuiltInAiEngine
    implements InferenceEngineProvider, HuggingFaceResolverSource {
  const BuiltInAiEngine();

  @override
  String get name => 'BuiltInAI';

  @override
  int get priority => 0;

  /// The engine's own Hugging Face resolver. Auto-registered by
  /// `FlutterGemma.initialize(inferenceEngines: …)` so it reserves the
  /// `.builtIn` slot: `resolveHuggingFace(fileType: builtIn)` (and the one-call
  /// `fromHuggingFace`) throws a clear `UnsupportedError` — the OS owns the
  /// weights, there is no Hugging Face file to resolve.
  @override
  HuggingFaceResolver get huggingFaceResolver =>
      const BuiltInAiHuggingFaceResolver();

  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.builtIn;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    if (config.supportAudio) {
      throw UnsupportedError(
        'Audio input is not supported by built-in OS models.',
      );
    }
    if (config.loraRanks?.isNotEmpty ?? false) {
      throw UnsupportedError(
        'LoRA ranks cannot be configured for a built-in OS model.',
      );
    }

    // Readiness is a hard precondition here, not something to wait out: the OS
    // feature download can take minutes and belongs to app startup, where it
    // can show progress. Callers drive it with BuiltInAi.ensureReady().
    final status = await BuiltInAi.availability();
    if (status != BuiltInAiAvailability.available) {
      throw BuiltInAiUnavailableException(
        status,
        'Built-in AI model "${spec.name}" is not available ($status). '
        'Call BuiltInAi.ensureReady() before creating the model.',
      );
    }

    // `create` probes the backend and throws `LocalAiUnsupportedException`
    // when vision was asked for and there is none — deliberately not caught or
    // downgraded here (see the class doc).
    final model = await LocalAiModel.create(
      maxTokens: config.maxTokens,
      supportImage: config.supportImage,
    );

    return BuiltInAiModel(
      model: model,
      modelType: spec.modelType,
      fileType: spec.fileType,
      maxTokens: config.maxTokens,
      supportImage: config.supportImage,
      maxNumImages: config.maxNumImages,
      maxConcurrentSessions: config.maxConcurrentSessions,
    );
  }
}
