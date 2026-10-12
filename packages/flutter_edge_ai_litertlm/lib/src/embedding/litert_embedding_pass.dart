// The `.tflite` embedding pass (EmbeddingGemma 1, Gecko) over the LiteRT C API
// — what `LiteRtEmbeddingBackend.describe` hands core for a two-file spec. Core
// builds it inside its embedding worker isolate, hosts it and closes it.
//
// `TokenEmbeddingPass` owns the tokenizer, the task prefix, the length check
// and the finalisation; this file owns only the native graph: env/model/
// options/compile, the sequence length and dimension read from the compiled
// tensor layouts, the zero-padded Int32/Float32 forward run (64-byte-aligned
// buffers, signature 0, and the Lock(Read) device→host sync — dropping that
// sync silently produces all-zero vectors on GPU/NPU), and reverse-order
// cleanup on failure.
//
// The compiled input's sequence length is the model's `maxInputTokens`: an
// input longer than that fails with `EmbeddingInputTooLongException` in
// `TokenEmbeddingPass.embed` before it reaches the graph. Until 2.3 the run
// silently kept the first `seqLen` ids instead.
//
// ⚠️ Invariant I0: the vector [LiteRtEmbeddingGraph.run] returns is the
// graph's own output copied verbatim — pooled and normalised by the compiled
// graph, never by Dart. The pass declares `EmbeddingOutputContract.pooledFinal`
// so `finalizeEmbedding` copies it through instead of running it through
// `meanPoolAndNormalize` a second time.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';
// Public, native-only bindings library (not the package barrel): this file is
// native-only — never reached on web — so it always needs the real FFI
// bindings. The package barrel's `if (dart.library.ffi)` export is for
// cross-platform consumers; `flutter analyze` resolves it to the empty web
// stub, so the bindings would appear undefined during analysis.
import 'package:flutter_edge_ai_litertlm/litert_bindings.dart';

/// What `LiteRtEmbeddingBackend.describe` hands core for a `.tflite` embedder.
///
/// Crosses to core's worker isolate: two paths and a top-level tokenizer
/// factory, all sendable.
final class LiteRtEmbeddingConfig {
  const LiteRtEmbeddingConfig({
    required this.modelPath,
    required this.tokenizerPath,
    required this.tokenizerFactory,
  });

  /// The `.tflite` file core resolved for the active spec.
  final String modelPath;

  /// The tokenizer file core resolved for the active spec.
  final String tokenizerPath;

  /// From core's tokenizer registry: which tokenizer family a model needs is
  /// a fact about the model, not about LiteRT.
  final EmbeddingTokenizerFactory tokenizerFactory;
}

/// The descriptor factory: a top-level tear-off, so it survives the trip into
/// core's worker isolate.
EmbeddingPass buildLiteRtEmbeddingPass(LiteRtEmbeddingConfig config) =>
    LiteRtEmbeddingPass(config);

/// The `.tflite` embedding pass. Text only; CPU only.
///
/// Built and run inside one isolate: the native handles it holds cannot cross
/// an isolate boundary — only its [LiteRtEmbeddingConfig] does.
final class LiteRtEmbeddingPass extends TokenEmbeddingPass {
  LiteRtEmbeddingPass(
    LiteRtEmbeddingConfig config, {
    @visibleForTesting LiteRtEmbeddingGraph? graph,
  }) : _modelPath = config.modelPath,
       _graph = graph ?? _NativeLiteRtEmbeddingGraph(),
       super(
         tokenizerPath: config.tokenizerPath,
         tokenizerFactory: config.tokenizerFactory,
       );

  final String _modelPath;
  final LiteRtEmbeddingGraph _graph;

  @override
  Future<TokenPassGraph> openGraph() async {
    final (:sequenceLength, :dimension) = _graph.open(_modelPath);
    return TokenPassGraph(
      dimension: dimension,
      // The compiled graph already emits the final pooled, normalised vector.
      outputContract: EmbeddingOutputContract.pooledFinal,
      // Read from the compiled input tensor `[1, seq]`. It counts every id
      // the tokenizer produced — task prefix, BOS and EOS included.
      maxInputTokens: sequenceLength,
    );
  }

  @override
  Future<ForwardResult> runTokens(TokenizedInput input) async {
    final values = _graph.run(input.ids);
    return ForwardResult(values: values, shape: [1, values.length]);
  }

  @override
  Future<void> closeGraph() async => _graph.close();
}

/// The native half of [LiteRtEmbeddingPass]: one compiled `.tflite` graph.
///
/// An interface so the pass's length check and lifecycle are testable without
/// the native library.
abstract interface class LiteRtEmbeddingGraph {
  /// Loads and compiles [modelPath]. Reports the compiled input's sequence
  /// length and the output's dimension. Frees whatever it created before
  /// throwing.
  ({int sequenceLength, int dimension}) open(String modelPath);

  /// One forward run over [ids] — at most `sequenceLength` of them, padded
  /// with 0 here. Returns the graph's output vector verbatim.
  List<double> run(List<int> ids);

  /// Frees the compiled model. Idempotent; safe before [open] and after a
  /// failed one.
  void close();
}

/// Backend selector for the LiteRT embedding graph. Only `cpu` is used: the
/// GPU delegate compiles and then returns all-zero vectors for
/// EmbeddingGemma's int4 weights (verified on macOS Metal), so embeddings are
/// never routed onto it, even "for symmetry" with inference.
enum EmbeddingBackend { cpu, gpu, npu }

int _acceleratorFor(EmbeddingBackend backend) {
  switch (backend) {
    case EmbeddingBackend.gpu:
      return kLiteRtHwAcceleratorGpu;
    case EmbeddingBackend.npu:
      return kLiteRtHwAcceleratorNpu;
    case EmbeddingBackend.cpu:
      return kLiteRtHwAcceleratorCpu;
  }
}

/// The production [LiteRtEmbeddingGraph]: the LiteRT C API. [allocator]
/// counts the pass's own pointer allocations in tests.
@visibleForTesting
LiteRtEmbeddingGraph nativeLiteRtEmbeddingGraph({
  Allocator allocator = calloc,
}) => _NativeLiteRtEmbeddingGraph(allocator);

/// [LiteRtEmbeddingGraph] over the LiteRT C API.
final class _NativeLiteRtEmbeddingGraph implements LiteRtEmbeddingGraph {
  _NativeLiteRtEmbeddingGraph([this._alloc = calloc]);

  /// Every pointer [open] allocates, and frees.
  final Allocator _alloc;

  final EmbeddingBackend backend = EmbeddingBackend.cpu;

  String _modelPath = '';
  LiteRtBindings? _bindings;
  LiteRtEnvironment? _environment;
  LiteRtModel? _model;
  LiteRtOptions? _options;
  LiteRtCompiledModel? _compiledModel;

  int? _sequenceLength;
  int? _dimension;
  bool _closed = false;

  @override
  ({int sequenceLength, int dimension}) open(String modelPath) {
    _modelPath = modelPath;
    final bindings = LiteRtBindings.open();
    _bindings = bindings;

    // Track native handles as they are created so a failure partway through
    // (e.g. a bad accelerator, or a non-embedding model with the wrong tensor
    // rank) frees everything already allocated instead of leaking it — the
    // LiteRT native heap is process-global and is NOT reclaimed by the
    // isolate dying.
    LiteRtEnvironment? environment;
    LiteRtModel? model;
    LiteRtOptions? options;
    LiteRtCompiledModel? compiled;
    try {
      // Each output pointer is freed in a `finally`: a failing `.check()`
      // must not leak it.
      final envPtr = _alloc<LiteRtEnvironment>();
      try {
        bindings
            .createEnvironment(0, nullptr, envPtr)
            .check('LiteRtCreateEnvironment');
        environment = envPtr.value;
      } finally {
        _alloc.free(envPtr);
      }

      // Model from .tflite file.
      final pathC = modelPath.toNativeUtf8(allocator: _alloc);
      try {
        final modelPtr = _alloc<LiteRtModel>();
        try {
          bindings
              .createModelFromFile(environment, pathC, modelPtr)
              .check('LiteRtCreateModelFromFile($modelPath)');
          model = modelPtr.value;
        } finally {
          _alloc.free(modelPtr);
        }
      } finally {
        _alloc.free(pathC);
      }

      _refuseMultiInputGraph(bindings, model);

      // Compilation options.
      final optsPtr = _alloc<LiteRtOptions>();
      try {
        bindings.createOptions(optsPtr).check('LiteRtCreateOptions');
        options = optsPtr.value;
      } finally {
        _alloc.free(optsPtr);
      }
      bindings
          .setOptionsHardwareAccelerators(options, _acceleratorFor(backend))
          .check('LiteRtSetOptionsHardwareAccelerators');

      // Compile.
      final compiledPtr = _alloc<LiteRtCompiledModel>();
      try {
        bindings
            .createCompiledModel(environment, model, options, compiledPtr)
            .check('LiteRtCreateCompiledModel');
        compiled = compiledPtr.value;
      } finally {
        _alloc.free(compiledPtr);
      }

      // seqLen + dim from the compiled tensor layouts.
      final int seqLen;
      final inLayout = LiteRtLayoutView.calloc();
      try {
        bindings
            .getInputTensorLayout(compiled, 0, 0, inLayout.pointer)
            .check('LiteRtGetCompiledModelInputTensorLayout');
        if (inLayout.rank < 2) {
          throw StateError(
            'Embedding model input has rank=${inLayout.rank}, expected >=2',
          );
        }
        seqLen = inLayout.dimension(1);
      } finally {
        inLayout.free();
      }

      final int dim;
      final outLayouts = LiteRtLayoutView.calloc();
      try {
        bindings
            .getOutputTensorLayouts(compiled, 0, 1, outLayouts.pointer, false)
            .check('LiteRtGetCompiledModelOutputTensorLayouts');
        if (outLayouts.rank < 2) {
          throw StateError(
            'Embedding model output has rank=${outLayouts.rank}, expected >=2',
          );
        }
        dim = outLayouts.dimension(1);
      } finally {
        outLayouts.free();
      }

      edgeAiLog(
        '[LiteRtEmbeddingPass] loaded: seqLen=$seqLen, dim=$dim, '
        'backend=$backend',
      );

      _environment = environment;
      _model = model;
      _options = options;
      _compiledModel = compiled;
      _sequenceLength = seqLen;
      _dimension = dim;
      return (sequenceLength: seqLen, dimension: dim);
    } catch (_) {
      // Free whatever was created, in reverse order, before rethrowing.
      if (compiled != null) bindings.destroyCompiledModel(compiled);
      if (options != null) bindings.destroyOptions(options);
      if (model != null) bindings.destroyModel(model);
      if (environment != null) bindings.destroyEnvironment(environment);
      rethrow;
    }
  }

  /// Rejects a graph this pass cannot feed, before paying the compile.
  ///
  /// [run] builds exactly one input tensor — the token ids — and calls
  /// `LiteRtRunCompiledModel` with `numInput: 1`. A BERT-style export that
  /// declares `attention_mask` and `token_type_ids` as separate inputs would
  /// otherwise fail inside the native runtime with a bare status code that
  /// names neither the model nor the reason.
  ///
  /// A supported LiteRT embedder is a single-input export with masking and
  /// pooling baked into the graph, which is what `litert-community` publishes
  /// for EmbeddingGemma and Gecko. The tokenizer is not consulted here: a
  /// multi-input graph is wrong for this pass whichever tokenizer produced
  /// the ids.
  void _refuseMultiInputGraph(LiteRtBindings bindings, LiteRtModel model) {
    final sigPtr = _alloc<LiteRtSignature>();
    final countPtr = _alloc<Size>();
    try {
      bindings
          .getModelSignature(model, 0, sigPtr)
          .check('LiteRtGetModelSignature');
      bindings
          .getNumSignatureInputs(sigPtr.value, countPtr)
          .check('LiteRtGetNumSignatureInputs');
      final count = countPtr.value;
      if (count == 1) return;

      final names = <String>[];
      final namePtr = _alloc<Pointer<Utf8>>();
      try {
        for (var i = 0; i < count; i++) {
          if (bindings.getSignatureInputName(sigPtr.value, i, namePtr) == 0 &&
              namePtr.value != nullptr) {
            names.add(namePtr.value.toDartString());
          }
        }
      } finally {
        _alloc.free(namePtr);
      }

      throw StateError(
        'LiteRT embedding model "$_modelPath" declares $count inputs'
        '${names.isEmpty ? '' : ' (${names.join(', ')})'} but this backend '
        'feeds exactly one: the token ids. It cannot supply attention_mask or '
        'token_type_ids to a compiled .tflite graph. Supported LiteRT '
        'embedders are single-input exports with masking and pooling baked '
        'into the graph (EmbeddingGemma / Gecko from litert-community). A '
        'multi-input BERT / MiniLM export belongs on the ONNX backend: add '
        'flutter_edge_ai_onnx, register OnnxEmbeddingBackend, and install the '
        '.onnx export of the same model.',
      );
    } finally {
      _alloc.free(sigPtr);
      _alloc.free(countPtr);
    }
  }

  @override
  List<double> run(List<int> ids) {
    final bindings = _bindings;
    final compiledModel = _compiledModel;
    final seq = _sequenceLength;
    final dim = _dimension;
    if (_closed ||
        bindings == null ||
        compiledModel == null ||
        seq == null ||
        dim == null) {
      throw StateError('LiteRtEmbeddingPass ran without an open graph');
    }
    if (ids.length > seq) {
      // TokenEmbeddingPass checks the length before the run; reaching this
      // would mean silently embedding the first `seq` ids, as 2.1 did.
      throw StateError(
        'LiteRtEmbeddingPass got ${ids.length} ids for a $seq-token graph',
      );
    }

    // All allocations live inside the try so a failure in either
    // createTensorBufferFromHostMemory (or runCompiledModel) frees everything
    // that was created instead of leaking it. Buffers are destroyed only if
    // they were actually created (the `*Created` flags).
    final inType = LiteRtRankedTensorTypeView.calloc()
      ..elementType = kLiteRtElementTypeInt32
      ..rank = 2
      ..setDimension(0, 1)
      ..setDimension(1, seq);
    final inAlloc = allocAligned(seq * 4);
    final inBufPtr = calloc<LiteRtTensorBuffer>();
    final outType = LiteRtRankedTensorTypeView.calloc()
      ..elementType = kLiteRtElementTypeFloat32
      ..rank = 2
      ..setDimension(0, 1)
      ..setDimension(1, dim);
    final outAlloc = allocAligned(dim * 4);
    final outBufPtr = calloc<LiteRtTensorBuffer>();
    var inBufCreated = false;
    var outBufCreated = false;

    try {
      final inHost = inAlloc.aligned.cast<Int32>();
      for (var i = 0; i < seq; i++) {
        inHost[i] = i < ids.length ? ids[i] : 0;
      }

      bindings
          .createTensorBufferFromHostMemory(
            inType.pointer,
            inAlloc.aligned.cast(),
            seq * 4,
            nullptr,
            inBufPtr,
          )
          .check('CreateTensorBufferFromHostMemory(input)');
      inBufCreated = true;

      bindings
          .createTensorBufferFromHostMemory(
            outType.pointer,
            outAlloc.aligned.cast(),
            dim * 4,
            nullptr,
            outBufPtr,
          )
          .check('CreateTensorBufferFromHostMemory(output)');
      outBufCreated = true;

      bindings
          .runCompiledModel(compiledModel, 0, 1, inBufPtr, 1, outBufPtr)
          .check('LiteRtRunCompiledModel');

      // Read the result through Lock, NOT from the raw host alloc. On CPU the
      // locked pointer is the same host memory, but on GPU/NPU the accelerator
      // writes into device memory and Lock(Read) triggers the device→host sync
      // (without it the host buffer stays zero — produces all-zero embeddings).
      final lockedPtr = calloc<Pointer<Void>>();
      try {
        bindings
            .lockTensorBuffer(
              outBufPtr.value,
              lockedPtr,
              kLiteRtTensorBufferLockModeRead,
            )
            .check('LiteRtLockTensorBuffer(output)');
        final outFloat = lockedPtr.value.cast<Float>();
        final result = List<double>.generate(dim, (i) => outFloat[i]);
        bindings.unlockTensorBuffer(outBufPtr.value);
        return result;
      } finally {
        calloc.free(lockedPtr);
      }
    } finally {
      if (inBufCreated) bindings.destroyTensorBuffer(inBufPtr.value);
      if (outBufCreated) bindings.destroyTensorBuffer(outBufPtr.value);
      calloc.free(inBufPtr);
      calloc.free(outBufPtr);
      calloc.free(inAlloc.raw);
      calloc.free(outAlloc.raw);
      inType.free();
      outType.free();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final bindings = _bindings;
    if (bindings == null) return; // open() never ran
    final compiled = _compiledModel;
    final options = _options;
    final model = _model;
    final environment = _environment;
    _compiledModel = null;
    _options = null;
    _model = null;
    _environment = null;
    if (compiled != null) bindings.destroyCompiledModel(compiled);
    if (options != null) bindings.destroyOptions(options);
    if (model != null) bindings.destroyModel(model);
    if (environment != null) bindings.destroyEnvironment(environment);
  }
}
