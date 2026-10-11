import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:llamadart/llamadart.dart' as llama;

import 'backend_config.dart';
import 'engine_queue.dart';
import 'llama_engine_provider.dart';
import 'model_location.dart'
    if (dart.library.js_interop) 'model_location_web.dart';

/// Registers GGUF embeddings using the tokenizer embedded in the model.
///
/// Core 2.1.3 still requires a tokenizer companion in its installation spec.
/// That companion is installed by core but never used by this runtime.
class LlamaEmbeddingProvider implements EmbeddingBackendProvider {
  /// Creates a provider; disable task prefixes for models not trained for them.
  const LlamaEmbeddingProvider({
    this.loader,
    this.contextSize = 4096,
    this.useTaskPrefixes = true,
  });

  /// Optional engine loading seam for tests.
  final LlamaEngineLoader? loader;

  /// Embedding context budget, since core passes zero in embedding RuntimeConfig.
  final int contextSize;

  /// Apply Edge AI's canonical retrieval query/document prefixes.
  final bool useTaskPrefixes;

  @override
  String get name => 'llamadart GGUF embeddings';
  @override
  int get priority => 0;
  @override
  bool canHandle(edge.EmbeddingModelSpec spec) =>
      spec.files.first.filename.toLowerCase().endsWith('.gguf');

  @override
  Future<edge.EmbeddingModel> createModel(
    edge.EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    if (!canHandle(spec)) {
      throw llama.LlamaUnsupportedException(
        'The embedding model must be GGUF.',
      );
    }
    if (contextSize <= 0) {
      throw llama.LlamaArgumentException(
        'Embedding contextSize must be positive.',
      );
    }
    if (config.preferredBackend == edge.PreferredBackend.npu) {
      throw llama.LlamaUnsupportedException(
        'GGUF embeddings cannot run on NPU.',
      );
    }
    final location = await resolveModelLocation(spec, config);
    if (location.isEmpty) {
      throw llama.LlamaArgumentException(
        'Install the embedding GGUF before loading it.',
      );
    }
    final device = switch (config.preferredBackend) {
      edge.PreferredBackend.cpu => llama.ComputeDevice.cpu,
      edge.PreferredBackend.gpu => llama.ComputeDevice.gpu,
      _ => llama.ComputeDevice.auto,
    };
    final engine = await (loader ?? loadGgufEngine)(
      location,
      llama.ModelParams(
        contextSize: contextSize,
        device: device,
        gpuLayers: device == llama.ComputeDevice.cpu
            ? 0
            : llama.ModelParams.maxGpuLayers,
      ),
    );
    try {
      if (engine.runtime != llama.LlamaRuntime.llamaCpp ||
          !(await engine.capabilities).supportsEmbeddings) {
        throw llama.LlamaUnsupportedException(
          'The active runtime does not report GGUF embedding support.',
        );
      }
      final layers = await engine.getResolvedGpuLayers();
      return LlamaEmbeddingModel(
        engine: engine,
        useTaskPrefixes: useTaskPrefixes,
        activeBackend: resolveBackend(layers, config.preferredBackend),
      );
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
  }
}

/// Lifecycle-safe Edge AI embedding model backed by llamadart embed/embedBatch.
class LlamaEmbeddingModel extends edge.EmbeddingModel with CloseNotifier {
  /// Takes ownership of [engine].
  LlamaEmbeddingModel({
    required this.engine,
    required this.activeBackend,
    this.useTaskPrefixes = true,
  });

  /// Engine used exclusively by this embedder.
  final llama.LlamaEngine engine;
  @override
  final edge.PreferredBackend? activeBackend;

  /// Whether to add retrieval task prefixes before tokenization.
  final bool useTaskPrefixes;
  final EngineQueue _queue = EngineQueue();
  bool _closed = false;
  Future<void>? _closing;
  int? _dimension;
  @override
  bool get isClosed => _closed;

  void _ensureOpen() {
    if (_closed) {
      throw llama.LlamaStateException('The embedding model is closed.');
    }
  }

  String _input(String text, edge.TaskType task) =>
      useTaskPrefixes ? '${task.prefix}$text' : text;

  void _checkVector(List<double> vector) {
    if (vector.isEmpty ||
        vector.any((n) => !n.isFinite) ||
        vector.every((n) => n == 0)) {
      throw llama.LlamaInferenceException(
        'The runtime returned an empty, nonfinite or all-zero embedding.',
      );
    }
    if (_dimension != null && vector.length != _dimension) {
      throw llama.LlamaInferenceException(
        'Embedding dimensions changed within one model instance.',
      );
    }
    _dimension = vector.length;
  }

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    edge.TaskType taskType = edge.TaskType.retrievalQuery,
  }) async {
    _ensureOpen();
    return (await _queue.run(() async {
      _ensureOpen();
      final result = await engine.embed(_input(text, taskType));
      _checkVector(result);
      return result;
    }))!;
  }

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    edge.TaskType taskType = edge.TaskType.retrievalQuery,
  }) async {
    _ensureOpen();
    final inputs = List<String>.of(texts);
    return (await _queue.run(() async {
      _ensureOpen();
      if (inputs.isEmpty) return <List<double>>[];
      final result = await engine.embedBatch([
        for (final text in inputs) _input(text, taskType),
      ]);
      if (result.length != inputs.length) {
        throw llama.LlamaInferenceException(
          'Embedding batch count does not match input count.',
        );
      }
      result.forEach(_checkVector);
      return result;
    }))!;
  }

  @override
  Future<int> getDimension() async {
    _ensureOpen();
    return (await _queue.run(() async {
      _ensureOpen();
      if (_dimension == null) {
        _checkVector(
          await engine.embed(
            _input('dimension probe', edge.TaskType.retrievalQuery),
          ),
        );
      }
      return _dimension!;
    }))!;
  }

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    return _closing = _queue.run<void>(() async {
      try {
        await engine.dispose();
      } finally {
        fireCloseListeners();
      }
    });
  }
}
