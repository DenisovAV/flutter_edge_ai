import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';

import 'litert_lm_log_level.dart';
import 'manifest/litertlm_manifest_resolver.dart' show LitertlmManifestResolver;
import 'thinking_token_budget.dart';
import 'web/litert_lm_web_inference.dart';

/// Web LiteRT-LM (`@litert-lm/core`) inference engine. A REAL engine (not a
/// stub): builds [LiteRtLmWebInferenceModel] from a [WebModelSourceResolver]
/// it constructs itself via `forActiveModel()`. `createModel` is a pure factory
/// — core owns the singleton lifecycle via [InferenceModel.addCloseListener].
class LiteRtLmEngine
    implements InferenceEngineProvider, HuggingFaceResolverSource {
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

  /// Checked as natively, then ignored: `@litert-lm/core` 0.18.0 takes no
  /// thinking budget. A load with one set says so once per isolate, in debug.
  final int? thinkingTokenBudget;

  @override
  String get name => 'LiteRT-LM';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.litertlm;

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
    // config.multimodalOrder is not read: the web session sends text only and
    // throws on an image or audio message (LiteRtLmWebSession.addQueryChunk).
    // A web path that sends media must put them where the order says.
    return LiteRtLmWebInferenceModel(
      sourceResolver: WebModelSourceResolver.forActiveModel(),
      maxTokens: config.maxTokens,
      modelType: spec.modelType,
      maxConcurrentSessions: config.maxConcurrentSessions,
      onClose: () {}, // core resets its state via addCloseListener
    );
  }
}
