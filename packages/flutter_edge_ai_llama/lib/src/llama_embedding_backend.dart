import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:llamadart/llamadart.dart' as llama;

import 'backend_config.dart';

const _engineTag = 'llamadart GGUF embeddings';
const _contextTokens = 1024;

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
  /// With [backendFallback] true, an explicit GPU request may fall back to
  /// CPU when GPU loading is unavailable. Core prints one release-visible
  /// warning per new fallback load and activeBackend reports CPU. With false, exactly one load
  /// attempt is allowed and a mismatch fails as EmbeddingLoadException.
  /// Automatic selection accepts CPU or GPU; unknown placement is refused.
  const LlamaEmbeddingBackend({this.backendFallback = true}) : _loader = null;

  const LlamaEmbeddingBackend._(this._loader, {this.backendFallback = true});
  final _EngineLoader? _loader;

  /// Whether an explicit GPU request may fall back to CPU.
  final bool backendFallback;

  @override
  String get name => _engineTag;

  @override
  int get priority => 10;

  @override
  bool canHandle(EmbeddingModelSpec spec) =>
      !kIsWeb &&
      spec.isSelfContained &&
      !isLiteRtLmFilename(spec.files.first.filename);

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
      ),
      activeBackend: null,
    );
  }
}

final class _PassConfig {
  const _PassConfig(this.path, this.backend, this.loader, this.backendFallback);
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
      throw const EmbeddingLoadException(
        'Only mean-pooled EmbeddingGemma 2 GGUF is qualified. '
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
    final normSquared = probe.fold<double>(
      0,
      (sum, value) => sum + value * value,
    );
    if (declared == null ||
        declared <= 0 ||
        probe.length != declared ||
        !probe.every((v) => v.isFinite) ||
        (normSquared - 1).abs() > 0.001) {
      throw const EmbeddingLoadException(
        'The GGUF runtime did not return the declared finite, normalized embedding.',
        engine: _engineTag,
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
    try {
      return await loader(_config.path, params);
    } catch (error) {
      final gpuUnavailable =
          error is llama.LlamaUnsupportedException ||
          error is llama.LlamaBackendInitializationException;
      if (!_config.backendFallback ||
          _config.backend != PreferredBackend.gpu ||
          !gpuUnavailable) {
        rethrow;
      }
      return loader(
        _config.path,
        params.copyWith(device: llama.ComputeDevice.cpu, gpuLayers: 0),
      );
    }
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final engine = _engine;
    if (_closed || engine == null || _dimension == null) {
      throw const EmbedderClosedException();
    }
    try {
      return await engine.embed(
        '${taskType.prefix}${input.text!}',
        normalize: true,
      );
    } on llama.LlamaEmbeddingInputTooLongException catch (error) {
      throw EmbeddingInputTooLongException(
        error.message,
        maxInputTokens: error.maxInputTokens,
        actualTokens: error.actualTokens,
      );
    } catch (error) {
      throw EmbeddingEngineException(
        'GGUF embedding failed.',
        engine: _engineTag,
        cause: error,
      );
    }
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
}) => LlamaEmbeddingBackend._(loader, backendFallback: backendFallback);
