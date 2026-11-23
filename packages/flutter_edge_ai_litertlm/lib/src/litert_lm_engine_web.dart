import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';

import 'catalog/litert_catalog.dart' show LiteRtLmModels;
import 'package:litertlm_dart/internal.dart' hide ActivationDataType;
import 'manifest/litertlm_manifest_resolver.dart' show LitertlmManifestResolver;
import 'thinking_token_budget.dart';
import 'adapter/runtime_log_binding.dart';
import 'adapter/web_inference_model.dart';
import 'web/web_llm_engine.dart';

/// Web LiteRT-LM (`@litert-lm/core`) inference engine. A REAL engine (not a
/// stub): builds [LiteRtLmWebInferenceModel] over litertlm_dart's web engine,
/// from a [WebModelSourceResolver] it constructs itself via
/// `forActiveModel()`. `createModel` is a pure factory
/// — core owns the singleton lifecycle via [InferenceModel.addCloseListener].
class LiteRtLmEngine
    implements
        InferenceEngineProvider,
        HuggingFaceResolverSource,
        ModelCatalogSource {
  const LiteRtLmEngine({
    this.backendFallback = true,
    this.nativeLogLevel,
    this.thinkingTokenBudget,
  });

  /// Read by the native engine only. The web engine runs on WebGPU and has no
  /// backend to fall back to.
  final bool backendFallback;

  /// Read by the native engine only: the web runtime has no such setting.
  final LiteRtLmLogLevel? nativeLogLevel;

  /// Checked as natively, then ignored: the web runtime takes no thinking
  /// budget (litertlm_dart refuses one there). A load with one set says so
  /// once per isolate, in debug.
  final int? thinkingTokenBudget;

  @override
  String get name => 'LiteRT-LM';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.litertlm;

  /// The LLMs this engine runs, pinned to Hugging Face commits:
  /// [LiteRtLmModels.catalog]. `FlutterEdgeAi.catalog` includes it once the
  /// engine is passed to `initialize`.
  @override
  ModelCatalog get modelCatalog => LiteRtLmModels.catalog;

  /// The engine's own Hugging Face resolver (reads `litertlm_manifest.json`).
  /// Auto-registered by `FlutterEdgeAi.initialize(inferenceEngines: …)` — same
  /// on web as native, so a repo's manifest resolves without a separate
  /// `huggingFaceResolvers:` list.
  @override
  HuggingFaceResolver get huggingFaceResolver =>
      const LitertlmManifestResolver();

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    checkThinkingTokenBudget(thinkingTokenBudget);
    if (thinkingTokenBudget != null) noticeThinkingTokenBudgetIgnoredOnWeb();
    bindRuntimeLogToCore();
    final sourceResolver = WebModelSourceResolver.forActiveModel();
    return LiteRtLmWebInferenceModel(
      createEngine: () => createLiteRtLmWebEngine(
        sourceResolver,
        maxTokens: config.maxTokens,
        supportImage: config.supportImage,
        supportAudio: config.supportAudio,
      ),
      maxTokens: config.maxTokens,
      modelType: spec.modelType,
      maxConcurrentSessions: config.maxConcurrentSessions,
      supportImage: config.supportImage,
      supportAudio: config.supportAudio,
      multimodalOrder: config.multimodalOrder,
      onClose: () {}, // core resets its state via addCloseListener
    );
  }
}
