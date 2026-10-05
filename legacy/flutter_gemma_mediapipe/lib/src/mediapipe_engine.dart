import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/registry/inference_engine_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show InferenceModel, supportedLoraRanks;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_gemma/core/domain/platform_types.dart' as core_types;
import 'package:flutter_gemma_mediapipe/pigeon.g.dart' as mp_pigeon;

import 'mobile/mobile_inference_model.dart';
import 'mobile/mobile_inference_session.dart' show platformService;

/// MediaPipe (.task/.bin) inference engine. Pure factory: drives the package's
/// own pigeon [platformService] to create the native model, then returns a bare
/// [MobileInferenceModel]; core owns the singleton lifecycle and registers its
/// reset via [InferenceModel.addCloseListener].
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
    await platformService.createModel(
      maxTokens: config.maxTokens,
      modelPath: config.modelPath,
      loraRanks: config.loraRanks ?? supportedLoraRanks,
      preferredBackend: _mapBackend(config.preferredBackend),
      maxNumImages: config.supportImage ? (config.maxNumImages ?? 1) : null,
      supportAudio: config.supportAudio ? true : null,
    );

    return MobileInferenceModel(
      maxTokens: config.maxTokens,
      modelType: spec.modelType,
      fileType: spec.fileType,
      // MobileInferenceModel stores core's PreferredBackend (its `activeBackend`
      // override must match the [InferenceModel] contract). Only the pigeon
      // `createModel` call above needs the package's enum, hence the map there.
      preferredBackend: config.preferredBackend,
      activeBackend: null,
      supportedLoraRanks: config.loraRanks ?? supportedLoraRanks,
      supportImage: config.supportImage,
      supportAudio: config.supportAudio,
      maxNumImages: config.maxNumImages,
      maxConcurrentSessions: config.maxConcurrentSessions,
      onClose: () {}, // no-op: core resets its own state via addCloseListener
    );
  }
}

/// Maps core's plain [core_types.PreferredBackend] (carried in [RuntimeConfig])
/// onto the package's own pigeon [mp_pigeon.PreferredBackend] (what the
/// package's pigeon [platformService] + [MobileInferenceModel] expect). Both
/// enums declare the same three values; this bridge keeps core's value type and
/// the package's pigeon enum from colliding now that MediaPipe lives in its own
/// package.
mp_pigeon.PreferredBackend? _mapBackend(core_types.PreferredBackend? b) =>
    switch (b) {
      null => null,
      core_types.PreferredBackend.cpu => mp_pigeon.PreferredBackend.cpu,
      core_types.PreferredBackend.gpu => mp_pigeon.PreferredBackend.gpu,
      core_types.PreferredBackend.npu => mp_pigeon.PreferredBackend.npu,
    };
