// Web arm of `OnnxEngine` (ONNX web PR, `feat/onnx-web`). Text generation on
// web routes through Transformers.js (`@huggingface/transformers`), NOT
// ORT-GenAI — a different model-provisioning story entirely (an HF-repo-id
// model, resolved and cached by Transformers.js itself, versus the native
// arm's ORT-GenAI model DIRECTORY). See [OnnxWebInferenceModel]'s module doc
// for the mechanics.
//
// Same public shape as the native arm (HARD RULE 2) — an app's
// `gemma_bootstrap.dart`-style registration list never needs an `if
// (kIsWeb)` branch to use it.
import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver;
import 'package:flutter_gemma/core/registry/hugging_face_resolver_source.dart'
    show HuggingFaceResolverSource;
import 'package:flutter_gemma/core/registry/inference_engine_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart' show InferenceModel;

import '../onnx_hugging_face_resolver.dart' show OnnxHuggingFaceResolver;
import 'onnx_web_inference_model.dart';
import 'transformers_web_resolver.dart';

/// ONNX Runtime GenAI on-device inference engine — web arm.
///
/// A REAL engine (not a stub): builds [OnnxWebInferenceModel] from a
/// [TransformersWebResolver] it constructs itself via `forActiveModel()`.
/// `createModel` is a pure factory — core owns the singleton lifecycle via
/// [InferenceModel.addCloseListener]. Text generation on web uses
/// Transformers.js (`@huggingface/transformers`), not ORT-GenAI; see
/// [OnnxWebInferenceModel]'s module doc for how that changes model identity
/// and the generation loop. Use `OnnxEmbeddingBackend` for the web
/// embeddings arm (onnxruntime-web).
class OnnxEngine implements InferenceEngineProvider, HuggingFaceResolverSource {
  const OnnxEngine();

  @override
  String get name => 'ONNX';

  @override
  int get priority => 0;

  /// The engine's own Hugging Face resolver ([OnnxHuggingFaceResolver]), shared
  /// with the native arm. On web it resolves a repo to a fileless model (the
  /// repo id Transformers.js fetches and caches itself), so `fromHuggingFace`
  /// and `resolveHuggingFace(fileType: onnx)` need no directory download.
  @override
  HuggingFaceResolver get huggingFaceResolver =>
      const OnnxHuggingFaceResolver();

  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.onnx;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    return OnnxWebInferenceModel(
      resolver: TransformersWebResolver.forActiveModel(),
      maxTokens: config.maxTokens,
      modelType: spec.modelType,
      preferredBackend: config.preferredBackend,
      onClose: () {}, // core resets its state via addCloseListener
    );
  }
}
