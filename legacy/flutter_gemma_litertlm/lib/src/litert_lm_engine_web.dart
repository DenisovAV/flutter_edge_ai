import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver;
import 'package:flutter_gemma/core/registry/hugging_face_resolver_source.dart'
    show HuggingFaceResolverSource;
import 'package:flutter_gemma/core/registry/inference_engine_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart' show InferenceModel;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_gemma/web/web_model_source.dart';

import 'manifest/litertlm_manifest_resolver.dart' show LitertlmManifestResolver;
import 'web/litert_lm_web_inference.dart';

/// Web LiteRT-LM (`@litert-lm/core`) inference engine. A REAL engine (not a
/// stub): builds [LiteRtLmWebInferenceModel] from a [WebModelSourceResolver]
/// it constructs itself via `forActiveModel()`. `createModel` is a pure factory
/// — core owns the singleton lifecycle via [InferenceModel.addCloseListener].
class LiteRtLmEngine
    implements InferenceEngineProvider, HuggingFaceResolverSource {
  const LiteRtLmEngine();

  @override
  String get name => 'LiteRT-LM';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.litertlm;

  /// The engine's own Hugging Face resolver (reads `litertlm_manifest.json`).
  /// Auto-registered by `FlutterGemma.initialize(inferenceEngines: …)` — same
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
    return LiteRtLmWebInferenceModel(
      sourceResolver: WebModelSourceResolver.forActiveModel(),
      maxTokens: config.maxTokens,
      modelType: spec.modelType,
      maxConcurrentSessions: config.maxConcurrentSessions,
      onClose: () {}, // core resets its state via addCloseListener
    );
  }
}
