import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

import 'backend_config.dart';
import 'llama_inference_model.dart';
import 'model_location.dart'
    if (dart.library.js_interop) 'model_location_web.dart';

/// Engine loading seam for deterministic connector contract tests.
typedef _LlamaEngineLoader =
    Future<llama.LlamaEngine> Function(String path, llama.ModelParams params);

/// Resolves the projector paired with the selected model, natively or on Web.
///
/// Core has no GGUF projector install slot. The app must install/cache the
/// projector and return its local path or browser URL through this resolver.
typedef LlamaProjectorResolver =
    Future<String?> Function(
      edge.InferenceModelSpec spec,
      RuntimeConfig config,
    );

/// Registers GGUF inference with Flutter Edge AI on native and Web runtimes.
///
/// Models are selected by the declared [edge.ModelFileType.gguf] type.
final class LlamaEngineProvider implements InferenceEngineProvider {
  /// Creates a provider, optionally resolving model-specific projectors.
  const LlamaEngineProvider({this.projectorResolver}) : _loader = null;

  /// Test-only injection; applications use the default constructor.
  // ignore: prefer_initializing_formals — keeps the test callback parameter readable.
  const LlamaEngineProvider._withLoader({
    required Future<llama.LlamaEngine> Function(String, llama.ModelParams)
    loader,
    this.projectorResolver,
  }) : _loader = loader; // ignore: prefer_initializing_formals

  /// Optional engine factory for tests.
  final _LlamaEngineLoader? _loader;

  /// Application-owned projector installation and pairing policy.
  final LlamaProjectorResolver? projectorResolver;

  @override
  String get name => 'llamadart GGUF';
  @override
  int get priority => 0;
  @override
  bool canHandle(edge.InferenceModelSpec spec) {
    return spec.fileType == edge.ModelFileType.gguf;
  }

  @override
  Future<edge.InferenceModel> createModel(
    edge.InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    if (!canHandle(spec)) {
      throw UnsupportedError('Declare the model as ModelFileType.gguf.');
    }
    if (config.maxTokens <= 0) {
      throw ArgumentError('A positive context size is required.');
    }
    if (config.activationDataType != null ||
        config.enableSpeculativeDecoding == true ||
        (config.loraRanks?.isNotEmpty ?? false)) {
      throw UnsupportedError(
        'LiteRT activation/MTP and MediaPipe LoRA-rank controls do not map to this GGUF connector.',
      );
    }
    if (config.preferredBackend == edge.PreferredBackend.npu) {
      throw UnsupportedError(
        'The llama.cpp GGUF runtime supports CPU/GPU, not NPU.',
      );
    }
    if ((config.maxConcurrentSessions ?? 1) < 1 ||
        (config.supportImage && (config.maxNumImages ?? 1) < 1)) {
      throw ArgumentError('Session and image limits must be positive.');
    }
    if (config.preferredVisionBackend != null ||
        config.preferredAudioBackend != null) {
      throw UnsupportedError(
        'llamadart does not expose separate vision/audio encoder backend selectors.',
      );
    }
    if ((config.supportImage || config.supportAudio) &&
        projectorResolver == null) {
      throw UnsupportedError(
        'Image/audio input requires a compatible GGUF projector. Configure projectorResolver on LlamaEngineProvider.',
      );
    }
    if (kIsWeb && spec.loraSource != null) {
      throw UnsupportedError(
        'This connector does not wire Web LoRA adapters; use a native runtime or install a model without an adapter.',
      );
    }
    final location = await resolveModelLocation(spec, config);
    if (location.isEmpty) {
      throw ArgumentError(
        'A resolved local path or installed Web model URL is required.',
      );
    }
    final device = switch (config.preferredBackend) {
      edge.PreferredBackend.cpu => llama.ComputeDevice.cpu,
      edge.PreferredBackend.gpu => llama.ComputeDevice.gpu,
      _ => llama.ComputeDevice.auto,
    };
    String? defaultLoraPath;
    if (spec.loraSource != null) {
      final paths =
          config.artifactPaths ??
          await edge.FlutterEdgeAiPlugin.instance.modelManager
              .getModelFilePaths(spec);
      defaultLoraPath = paths?[spec.files[1].prefsKey];
      if (defaultLoraPath == null) {
        throw StateError(
          'Install the LoRA companion before loading this model.',
        );
      }
    }
    final params = llama.ModelParams(
      contextSize: config.maxTokens,
      loras: [
        if (defaultLoraPath != null)
          llama.LoraAdapterConfig.source(
            llama.ModelSource.path(defaultLoraPath),
          ),
      ],
      device: device,
      gpuLayers: device == llama.ComputeDevice.cpu
          ? 0
          : llama.ModelParams.maxGpuLayers,
    );
    final engine = await (_loader ?? _loadGgufEngine)(location, params);
    try {
      if (engine.runtime != llama.LlamaRuntime.llamaCpp) {
        throw UnsupportedError('GGUF must resolve to the llama.cpp runtime.');
      }
      if (config.supportImage || config.supportAudio) {
        final projector = await projectorResolver!(spec, config);
        if (projector == null) {
          throw UnsupportedError('No projector is paired with this model.');
        }
        if (projector.trim().isEmpty) {
          throw ArgumentError('Projector location must be nonempty.');
        }
        final uri = Uri.tryParse(projector);
        final windowsPath = RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(projector);
        if (kIsWeb &&
                (uri == null ||
                    !['http', 'https', 'blob'].contains(uri.scheme)) ||
            !kIsWeb && uri != null && uri.hasScheme && !windowsPath) {
          throw ArgumentError(
            kIsWeb
                ? 'Return an HTTP(S) or cached blob projector URL.'
                : 'Return an installed local projector path.',
          );
        }
        final source = kIsWeb
            ? llama.ModelSource.url(Uri.parse(projector))
            : llama.ModelSource.path(projector);
        await engine.loadMultimodalProjectorSource(source);
        final capabilities = await engine.capabilities;
        if (config.supportImage && !capabilities.supportsVision ||
            config.supportAudio && !capabilities.supportsAudio) {
          throw UnsupportedError(
            'The loaded projector does not report the requested vision/audio capability.',
          );
        }
      }
      var backendName = await engine.getBackendName();
      // The Web bridge's name lists available devices. In the published SDK,
      // isGpuSupported queries the loaded bridge's isGpuActive flag instead.
      if (kIsWeb && backendName.toLowerCase().contains('webgpu')) {
        backendName = await engine.isGpuSupported() ? 'WebGPU' : 'WASM';
      }
      return LlamaInferenceModel(
        engine: engine,
        modelType: spec.modelType,
        maxTokens: await engine.getContextSize(),
        activeBackend: resolveBackend(backendName, config.preferredBackend),
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
Future<llama.LlamaEngine> _loadGgufEngine(
  String location,
  llama.ModelParams params,
) => llama.LlamaEngine.load(
  llama.LlamaModel(
    llama.ModelSource.path(location, format: llama.ModelFormat.gguf),
  ),
  params: params,
);

/// Internal injection seam for connector tests; not exported by the package.
@visibleForTesting
LlamaEngineProvider createLlamaProviderForTest({
  required Future<llama.LlamaEngine> Function(String, llama.ModelParams) loader,
  LlamaProjectorResolver? projectorResolver,
}) => LlamaEngineProvider._withLoader(
  loader: loader,
  projectorResolver: projectorResolver,
);
