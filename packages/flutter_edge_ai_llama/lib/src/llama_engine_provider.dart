import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

import 'backend_config.dart';
import 'llama_inference_model.dart';
import 'model_location.dart'
    if (dart.library.js_interop) 'model_location_web.dart';

/// Engine loading seam for deterministic connector contract tests.
typedef LlamaEngineLoader = Future<llama.LlamaEngine> Function(
  String path,
  llama.ModelParams params,
);

/// Resolves the projector paired with the selected model, natively or on Web.
///
/// Core has no GGUF projector install slot. The app must install/cache the
/// projector and return its local path or browser URL through this resolver.
typedef LlamaProjectorResolver = Future<llama.ModelSource?> Function(
  edge.InferenceModelSpec spec,
  RuntimeConfig config,
);

/// Registers GGUF inference with Flutter Edge AI on native and Web runtimes.
///
/// Only binary specs ending in `.gguf` are claimed until core adds GGUF identity.
class LlamaEngineProvider implements InferenceEngineProvider {
  /// Creates a provider, optionally resolving model-specific projectors.
  const LlamaEngineProvider({this.loader, this.projectorResolver});

  /// Optional engine factory for tests.
  final LlamaEngineLoader? loader;

  /// Application-owned projector installation and pairing policy.
  final LlamaProjectorResolver? projectorResolver;

  @override
  String get name => 'llamadart GGUF';
  @override
  int get priority => 0;
  @override
  bool canHandle(edge.InferenceModelSpec spec) {
    return spec.fileType == edge.ModelFileType.binary &&
        spec.files.first.filename.toLowerCase().endsWith('.gguf');
  }

  @override
  Future<edge.InferenceModel> createModel(
    edge.InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    if (!canHandle(spec)) {
      throw llama.LlamaUnsupportedException(
        'Declare a .gguf model as ModelFileType.binary.',
      );
    }
    if (config.maxTokens <= 0) {
      throw llama.LlamaArgumentException(
        'A positive context size is required.',
      );
    }
    if (config.activationDataType != null ||
        config.enableSpeculativeDecoding == true ||
        (config.loraRanks?.isNotEmpty ?? false)) {
      throw llama.LlamaUnsupportedException(
        'LiteRT activation/MTP and MediaPipe LoRA-rank controls do not map to this GGUF connector.',
      );
    }
    if (config.preferredBackend == edge.PreferredBackend.npu) {
      throw llama.LlamaUnsupportedException(
        'The llama.cpp GGUF runtime supports CPU/GPU, not NPU.',
      );
    }
    if ((config.maxConcurrentSessions ?? 1) < 1 ||
        (config.supportImage && (config.maxNumImages ?? 1) < 1)) {
      throw llama.LlamaArgumentException(
        'Session and image limits must be positive.',
      );
    }
    if (config.preferredVisionBackend != null ||
        config.preferredAudioBackend != null) {
      throw llama.LlamaUnsupportedException(
        'llamadart does not expose separate vision/audio encoder backend selectors.',
      );
    }
    if ((config.supportImage || config.supportAudio) &&
        projectorResolver == null) {
      throw llama.LlamaUnsupportedException(
        'Image/audio input requires a compatible GGUF projector. Configure projectorResolver on LlamaEngineProvider.',
      );
    }
    if (kIsWeb && spec.loraSource != null) {
      throw llama.LlamaUnsupportedException(
        'Native LoRA runtime operations are unavailable on Web in llamadart 0.11.1.',
      );
    }
    final location = await resolveModelLocation(spec, config);
    if (location.isEmpty) {
      throw llama.LlamaArgumentException(
        'A resolved local path or installed Web model URL is required.',
      );
    }
    final device = switch (config.preferredBackend) {
      edge.PreferredBackend.cpu => llama.ComputeDevice.cpu,
      edge.PreferredBackend.gpu => llama.ComputeDevice.gpu,
      _ => llama.ComputeDevice.auto,
    };
    final params = llama.ModelParams(
      contextSize: config.maxTokens,
      device: device,
      gpuLayers: device == llama.ComputeDevice.cpu
          ? 0
          : llama.ModelParams.maxGpuLayers,
    );
    final engine = await (loader ?? loadGgufEngine)(location, params);
    try {
      if (engine.runtime != llama.LlamaRuntime.llamaCpp) {
        throw llama.LlamaUnsupportedException(
          'GGUF must resolve to the llama.cpp runtime.',
        );
      }
      if (config.supportImage || config.supportAudio) {
        final projector = await projectorResolver!(spec, config);
        if (projector == null) {
          throw llama.LlamaUnsupportedException(
            'No projector is paired with this model.',
          );
        }
        await engine.loadMultimodalProjectorSource(projector);
        final capabilities = await engine.capabilities;
        if (config.supportImage && !capabilities.supportsVision ||
            config.supportAudio && !capabilities.supportsAudio) {
          throw llama.LlamaUnsupportedException(
            'The loaded projector does not report the requested vision/audio capability.',
          );
        }
      }
      String? defaultLoraPath;
      if (spec.loraSource != null) {
        final paths =
            config.artifactPaths ??
            await edge.FlutterEdgeAiPlugin.instance.modelManager
                .getModelFilePaths(spec);
        defaultLoraPath = paths?[spec.files[1].prefsKey];
        if (defaultLoraPath == null) {
          throw llama.LlamaStateException(
            'Install the LoRA companion before loading this model.',
          );
        }
      }
      final layers = await engine.getResolvedGpuLayers();
      return LlamaInferenceModel(
        engine: engine,
        modelType: spec.modelType,
        maxTokens: await engine.getContextSize(),
        activeBackend: resolveBackend(layers, config.preferredBackend),
        supportImage: config.supportImage,
        supportAudio: config.supportAudio,
        maxNumImages: config.maxNumImages,
        maxConcurrentSessions: config.maxConcurrentSessions,
        defaultLoraPath: defaultLoraPath,
      );
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
  }
}

/// Loads GGUF with an explicit format, including installed extensionless blob URLs.
Future<llama.LlamaEngine> loadGgufEngine(
  String location,
  llama.ModelParams params,
) => llama.LlamaEngine.load(
  llama.LlamaModel(
    llama.ModelSource.path(location, format: llama.ModelFormat.gguf),
  ),
  params: params,
);
