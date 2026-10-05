import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/registry/inference_engine_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart' show InferenceModel;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_gemma/web/web_model_source.dart';

import 'web/web_inference_model.dart';

/// Web MediaPipe (`@mediapipe/tasks-genai`) inference engine. A REAL engine
/// (not a stub): builds [WebInferenceModel] from a [WebModelSourceResolver] it
/// constructs itself via `forActiveModel()`. `createModel` is a pure factory —
/// core owns the singleton lifecycle via [InferenceModel.addCloseListener].
/// Web ignores `PreferredBackend` (MediaPipe JS uses WebGPU when available).
class MediaPipeEngine implements InferenceEngineProvider {
  const MediaPipeEngine();

  @override
  String get name => 'MediaPipe';

  @override
  int get priority => 0;

  @override
  bool canHandle(InferenceModelSpec spec) =>
      spec.fileType == ModelFileType.task ||
      spec.fileType == ModelFileType.binary;

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    return WebInferenceModel(
      sourceResolver: WebModelSourceResolver.forActiveModel(),
      modelType: spec.modelType,
      fileType: spec.fileType,
      maxTokens: config.maxTokens,
      loraRanks: config.loraRanks,
      supportImage: config.supportImage,
      supportAudio: config.supportAudio,
      maxNumImages: config.maxNumImages,
      maxConcurrentSessions: config.maxConcurrentSessions,
      onClose: () {}, // core owns lifecycle via addCloseListener
    );
  }
}
