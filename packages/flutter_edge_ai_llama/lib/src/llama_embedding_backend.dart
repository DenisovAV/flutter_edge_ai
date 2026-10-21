import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:llamadart/llamadart.dart' as llama;

import 'backend_config.dart';
import 'embedding_platform.dart';

const _engineTag = 'llamadart GGUF embeddings';
const _contextTokens = 1024;

bool _isQualifiedVector(List<double> vector, int? dimension) {
  if (dimension == null ||
      dimension <= 0 ||
      vector.length != dimension ||
      !vector.every((value) => value.isFinite)) {
    return false;
  }
  final normSquared = vector.fold<double>(
    0,
    (sum, value) => sum + value * value,
  );
  return (normSquared - 1).abs() <= 0.001;
}

String _vectorFailureDetails(List<double> vector, int? dimension) {
  final finite = vector.every((value) => value.isFinite);
  final normSquared = vector.fold<double>(
    0,
    (sum, value) => sum + value * value,
  );
  return 'expected dimension: ${dimension ?? "missing or invalid"}, '
      'actual dimension: ${vector.length}, finite: $finite, '
      'squared norm: $normSquared (required |squared norm - 1| <= 0.001)';
}

typedef _EngineLoader =
    Future<llama.LlamaEngine> Function(String path, llama.ModelParams params);

/// Native EmbeddingGemma 2 GGUF text embeddings through llamadart.
///
/// Register in `FlutterEdgeAi.initialize(embeddingBackends: [...])`. Install
/// one `.gguf` file through `installEmbedder()`; no tokenizer package or
/// companion tokenizer is needed. Core owns the model, worker queue and close.
///
/// This first profile accepts only `gemma-embedding2`, uses core's nine
/// TaskType prefixes, mean pooling from the model, L2 normalization, and a
/// 1024-token input budget including the prefix and special tokens. Other GGUF
/// architectures are refused at load rather than given Gemma prompts.
///
/// Automatic requests reuse the current non-NPU embedder for the same model.
/// Repeated explicit CPU/GPU requests reuse their originating model, including
/// a fallback, until a rebuild is needed or it is closed. NPU, media and Web
/// embeddings are unavailable in this profile. Give GGUF its own RAG
/// profile ID; equal dimensions do not make it interchangeable with LiteRT.
final class LlamaEmbeddingBackend extends EmbeddingBackendProvider {
  /// Creates the qualified native text embedding provider.
  /// With [backendFallback] true, an explicit GPU request may retry once on
  /// CPU after LlamaUnsupportedException. Android and iOS simulators refuse
  /// explicit GPU attempts before loading. Other load errors are not retried.
  /// Automatic selection accepts CPU or GPU and warns when it selects CPU.
  /// With false, explicit placement mismatches fail as EmbeddingLoadException.
  /// Unknown placement is always refused.
  const LlamaEmbeddingBackend({this.backendFallback = true})
    : _loader = null,
      _gpuRefusal = null;

  const LlamaEmbeddingBackend._(
    this._loader,
    this._gpuRefusal, {
    this.backendFallback = true,
  });
  final String? Function()? _gpuRefusal;
  final _EngineLoader? _loader;

  /// Whether an unsupported explicit GPU request may retry once on CPU.
  final bool backendFallback;

  @override
  String get name => _engineTag;

  @override
  int get priority => 10;

  @override
  bool canHandle(EmbeddingModelSpec spec) =>
      !kIsWeb &&
      spec.isSelfContained &&
      spec.files.first.filename.toLowerCase().endsWith('.gguf');

  @override
  Set<PreferredBackend> honouredBackends(EmbeddingModelSpec spec) =>
      kIsWeb ? const {} : const {PreferredBackend.cpu, PreferredBackend.gpu};

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    if (kIsWeb) {
      throw const EmbeddingLoadException(
        'GGUF text embeddings are qualified on native runtimes only. '
        'Web needs structured overflow reporting and its own qualification.',
        engine: _engineTag,
      );
    }
    if (!canHandle(spec) ||
        !spec.isSelfContained ||
        config.tokenizerPath != null) {
      throw const EmbeddingLoadException(
        'Install a self-contained .gguf embedding model without a tokenizer.',
        engine: _engineTag,
      );
    }
    if (config.supportImage || config.supportAudio) {
      throw const EmbeddingLoadException(
        'This GGUF embedding profile serves text only; media needs separate qualification.',
        engine: _engineTag,
      );
    }
    if (config.preferredBackend == PreferredBackend.npu) {
      throw const EmbeddingLoadException(
        'The llama.cpp embedding runtime supports CPU/GPU, not NPU.',
        engine: _engineTag,
      );
    }
    if (config.modelPath.isEmpty || config.modelPath.startsWith('opfs://')) {
      throw const EmbeddingLoadException(
        'An installed local GGUF model path is required.',
        engine: _engineTag,
      );
    }
    return EmbeddingPassDescriptor<_PassConfig>(
      engineTag: _engineTag,
      factory: _buildPass,
      config: _PassConfig(
        config.modelPath,
        config.preferredBackend,
        _loader,
        backendFallback,
        _gpuRefusal,
      ),
      activeBackend: null,
    );
  }
}

final class _PassConfig {
  const _PassConfig(
    this.path,
    this.backend,
    this.loader,
    this.backendFallback,
    this.gpuRefusal,
  );
  final String? Function()? gpuRefusal;
  final String path;
  final PreferredBackend? backend;
  final _EngineLoader? loader;
  final bool backendFallback;
}

EmbeddingPass _buildPass(_PassConfig config) => _LlamaEmbeddingPass(config);

final class _LlamaEmbeddingPass extends EmbeddingPass {
  _LlamaEmbeddingPass(this._config);
  final _PassConfig _config;
  llama.LlamaEngine? _engine;
  bool _closed = false;
  int? _dimension;

  @override
  Future<EmbeddingPassInfo> load() async {
    final device = switch (_config.backend) {
      PreferredBackend.cpu => llama.ComputeDevice.cpu,
      PreferredBackend.gpu => llama.ComputeDevice.gpu,
      _ => llama.ComputeDevice.auto,
    };
    // Pooled non-causal inputs must fit in ONE micro-batch. Chat's default
    // micro-batch would reject or split input below the advertised budget.
    final params = llama.ModelParams(
      contextSize: _contextTokens,
      batchSize: _contextTokens,
      microBatchSize: _contextTokens,
      maxParallelSequences: 1,
      device: device,
      gpuLayers: device == llama.ComputeDevice.cpu
          ? 0
          : llama.ModelParams.maxGpuLayers,
    );
    final llama.LlamaEngine engine;
    try {
      engine = await _load(params);
    } catch (error, stack) {
      if (error is EmbeddingLoadException) rethrow;
      Error.throwWithStackTrace(
        EmbeddingLoadException(
          'Could not load the GGUF embedding runtime.',
          engine: _engineTag,
          cause: error,
        ),
        stack,
      );
    }
    _engine = engine;
    if (engine.runtime != llama.LlamaRuntime.llamaCpp) {
      throw const EmbeddingLoadException(
        'GGUF must use llama.cpp.',
        engine: _engineTag,
      );
    }
    final metadata = await engine.getMetadata();
    if (metadata['general.architecture'] != 'gemma-embedding2' ||
        metadata['gemma-embedding2.pooling_type'] != '1') {
      throw EmbeddingLoadException(
        'Only mean-pooled EmbeddingGemma 2 GGUF is qualified. '
        'Found architecture: ${metadata["general.architecture"] ?? "missing"}, '
        'pooling type: ${metadata["gemma-embedding2.pooling_type"] ?? "missing"}. '
        'Other models require their own prompting and pooling qualification.',
        engine: _engineTag,
      );
    }
    if (!(await engine.embeddingCapabilities).text) {
      throw const EmbeddingLoadException(
        'The loaded runtime cannot embed text.',
        engine: _engineTag,
      );
    }
    final actualContext = await engine.getContextSize();
    if (actualContext != _contextTokens) {
      throw EmbeddingLoadException(
        'Requested $_contextTokens context tokens, but loaded $actualContext.',
        engine: _engineTag,
      );
    }
    final activeBackend = resolveBackend(await engine.getBackendName(), null);
    if (activeBackend == null ||
        (_config.backend == PreferredBackend.cpu &&
            activeBackend != PreferredBackend.cpu) ||
        (!_config.backendFallback &&
            _config.backend != null &&
            activeBackend != _config.backend)) {
      throw EmbeddingLoadException(
        'Could not verify the requested GGUF embedding placement: '
        'requested ${_config.backend?.name ?? "automatic"}, '
        'loaded ${activeBackend?.name ?? "unknown"}.',
        engine: _engineTag,
      );
    }
    // The transformer width differs from the output projection (512 vs 768
    // for EG2). Probe the real output rather than guess from embedding_length.
    final probe = await engine.embed(
      'embedding qualification',
      normalize: true,
    );
    final declared = int.tryParse(
      metadata['gemma-embedding2.embedding_length_out'] ?? '',
    );
    if (!_isQualifiedVector(probe, declared)) {
      throw EmbeddingLoadException(
        'The GGUF runtime did not return the declared finite, normalized embedding: '
        '${_vectorFailureDetails(probe, declared)}; '
        'declared embedding_length_out: '
        '${metadata["gemma-embedding2.embedding_length_out"] ?? "missing"}.',
        engine: _engineTag,
      );
    }
    if (params.device == llama.ComputeDevice.auto &&
        params.gpuLayers > 0 &&
        activeBackend == PreferredBackend.cpu &&
        // llamadart resolves automatic placement to CPU on Android and iOS
        // simulators, the same targets that refuse explicit GPU embeddings.
        (_config.gpuRefusal ?? nativeEmbeddingGpuRefusal)() == null) {
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_llama] WARNING: automatic GGUF embedding '
        'load requested GPU layers but selected CPU.',
      );
    }
    _dimension = probe.length;
    return EmbeddingPassInfo(
      dimension: probe.length,
      maxInputTokens: _contextTokens,
      activeBackend: activeBackend,
    );
  }

  Future<llama.LlamaEngine> _load(llama.ModelParams params) async {
    // LlamaEngine.load is atomic: on failure it awaits disposal of the engine
    // and backend. Test loaders have the same contract. A CPU retry therefore
    // never overlaps a partial GPU engine. Model/metadata validation below is
    // outside this retry boundary and is never retried.
    final loader = _config.loader ?? _loadEngine;
    Future<llama.LlamaEngine> attempt(llama.ModelParams attemptParams) async {
      if (attemptParams.device == llama.ComputeDevice.gpu) {
        final refusal = (_config.gpuRefusal ?? nativeEmbeddingGpuRefusal)();
        if (refusal != null) throw llama.LlamaUnsupportedException(refusal);
      }
      return loader(_config.path, attemptParams);
    }

    try {
      return await attempt(params);
    } catch (first, firstStack) {
      if (!_config.backendFallback ||
          params.device != llama.ComputeDevice.gpu ||
          first is! llama.LlamaUnsupportedException) {
        Error.throwWithStackTrace(first, firstStack);
      }
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_llama] WARNING: GPU embedding load unavailable: '
        '$first; retrying on CPU.',
      );
      try {
        return await attempt(
          params.copyWith(device: llama.ComputeDevice.cpu, gpuLayers: 0),
        );
      } catch (second, secondStack) {
        Error.throwWithStackTrace(
          EmbeddingLoadException(
            'GPU attempt failed: $first. CPU retry failed: $second.',
            engine: _engineTag,
            cause: second,
          ),
          secondStack,
        );
      }
    }
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final engine = _engine;
    if (_closed || engine == null || _dimension == null) {
      throw const EmbedderClosedException();
    }
    final List<double> vector;
    try {
      vector = await engine.embed(
        '${taskType.prefix}${input.text!}',
        normalize: true,
      );
    } on llama.LlamaEmbeddingInputTooLongException catch (error, stack) {
      Error.throwWithStackTrace(
        EmbeddingInputTooLongException(
          error.message,
          maxInputTokens: error.maxInputTokens,
          actualTokens: error.actualTokens,
        ),
        stack,
      );
    } catch (error, stack) {
      Error.throwWithStackTrace(
        EmbeddingEngineException(
          'GGUF embedding failed.',
          engine: _engineTag,
          cause: error,
        ),
        stack,
      );
    }
    if (!_isQualifiedVector(vector, _dimension)) {
      throw EmbeddingEngineException(
        'The GGUF runtime returned an invalid embedding vector: '
        '${_vectorFailureDetails(vector, _dimension)}.',
        engine: _engineTag,
      );
    }
    return vector;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }
}

Future<llama.LlamaEngine> _loadEngine(String path, llama.ModelParams params) =>
    llama.LlamaEngine.load(
      llama.LlamaModel(
        llama.ModelSource.path(path, format: llama.ModelFormat.gguf),
      ),
      params: params,
    );

/// Internal test seam; applications use the constant default constructor.
@visibleForTesting
LlamaEmbeddingBackend createLlamaEmbeddingBackendForTest({
  required Future<llama.LlamaEngine> Function(String, llama.ModelParams) loader,
  bool backendFallback = true,
  String? Function()? gpuRefusal,
}) => LlamaEmbeddingBackend._(
  loader,
  gpuRefusal,
  backendFallback: backendFallback,
);
