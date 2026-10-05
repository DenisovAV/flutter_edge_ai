// LiteRT C API embedding forward pass — the engine-specific half of the
// embedder decoupling seam (embedder decoupling plan Task 4).
//
// This is the FFI body that used to live in
// `flutter_gemma_embeddings/lib/src/litert/litert_embedding_core.dart`
// (`EmbeddingCore`), ported verbatim MINUS tokenization — tokenization
// (BOS/EOS + prefix, Invariant I1) now lives in
// `flutter_gemma_embeddings/lib/src/embedding_tokenizer.dart` and is applied
// by the common worker before `run()` is ever called here. This file keeps
// only the native lifecycle: env/model/options/compile, seqLen/dim
// auto-detect, the pad/truncate + Int32/Float32 tensor forward pass
// (including the 64-byte-aligned buffers, signature-0 run, and the
// Lock(Read) device→host sync — dropping that sync silently produces
// all-zero vectors on GPU/NPU), and reverse-order cleanup on failure.
//
// ⚠️ Invariant I0: [ForwardResult.values] returned by [run] is the raw,
// already-pooled/normalized-by-the-graph output copied verbatim
// (`List<double>.generate(dim, ...)`- no Dart-side pooling, no
// normalization happens here or anywhere in this file. The
// [EmbeddingOutputContract.pooledFinal] the backend declares (see
// `litert_embedding_backend.dart`) is what tells the common worker to copy
// this vector through unchanged instead of running it through
// `meanPoolAndNormalize` a second time.

import 'dart:ffi';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

import 'package:ffi/ffi.dart';
// Imported by file rather than through core's barrel: the seam is plain,
// platform-agnostic Dart with no conditional split, while the barrel also
// carries `CommonEmbeddingModel` behind an `if (dart.library.js_interop)` —
// the same analyzer quirk `litert_bindings.dart` below works around.
import 'package:flutter_gemma/core/embedding/forward_pass.dart'
    show EmbeddingForwardPass, EmbeddingOutputContract, ForwardResult;
// Public, native-only bindings library (not the package barrel): this file
// is native-only — never reached on web — so it always needs the real FFI
// bindings. Going through this package's own top-level barrel
// (`flutter_gemma_litertlm.dart`)'s `if (dart.library.ffi)` conditional
// export is for cross-platform consumers that must also compile on web;
// `flutter analyze` resolves that conditional to the (empty) web stub, so
// importing the concrete file would appear undefined during analysis.
// `litert_bindings.dart` is this package's unconditional public export of
// the same bindings for native-only leaves — imported here as an
// intra-package import for the same reason capability packages
// (flutter_gemma_embeddings pre-refactor, flutter_gemma_speech) use it.
import 'package:flutter_gemma_litertlm/litert_bindings.dart';

/// Backend selector for the LiteRT embedding forward pass. Only `cpu` is
/// wired up end-to-end today — see [createLiteRtEmbeddingForwardPass].
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

/// LiteRT C API implementation of the [EmbeddingForwardPass] seam. NOT safe
/// to share across isolates — the FFI handles it holds are owned by the
/// isolate that called [load]; see `ForwardPassDescriptor`'s doc for how the
/// *ability to build one* (not the instance itself) crosses an isolate
/// boundary via [createLiteRtEmbeddingForwardPass].
class LiteRtEmbeddingForwardPass implements EmbeddingForwardPass {
  LiteRtEmbeddingForwardPass(
    this._modelPath, {
    this.backend = EmbeddingBackend.cpu,
    int? inputSequenceLength,
    int? outputDimension,
  }) : _pinnedSeqLen = inputSequenceLength,
       _pinnedDim = outputDimension;

  final String _modelPath;
  final EmbeddingBackend backend;
  final int? _pinnedSeqLen;
  final int? _pinnedDim;

  LiteRtBindings? _bindings;
  LiteRtEnvironment? _environment;
  LiteRtModel? _model;
  LiteRtOptions? _options;
  LiteRtCompiledModel? _compiledModel;

  int? _inputSequenceLength;
  int? _outputDimension;
  bool _disposed = false;

  @override
  int get outputDimension {
    final dim = _outputDimension;
    if (dim == null) {
      throw StateError('LiteRtEmbeddingForwardPass.load() has not completed');
    }
    return dim;
  }

  @override
  int? get inputSequenceLength => _inputSequenceLength;

  // LiteRT never overrides the descriptor's outputContract — its descriptor
  // always declares `pooledFinal` (see `litert_embedding_backend.dart`) and
  // this stays `null` per design D-T2's doc on
  // `EmbeddingForwardPass.outputContract`.
  @override
  EmbeddingOutputContract? get outputContract => null;

  /// Load and compile the `.tflite` embedding model for [backend]. Heavy
  /// (compile is ~570-780ms) — call once, from a background isolate.
  @override
  Future<void> load() async {
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
      final envPtr = calloc<LiteRtEnvironment>();
      bindings
          .createEnvironment(0, nullptr, envPtr)
          .check('LiteRtCreateEnvironment');
      environment = envPtr.value;
      calloc.free(envPtr);

      // Model from .tflite file.
      final pathC = _modelPath.toNativeUtf8();
      final modelPtr = calloc<LiteRtModel>();
      try {
        bindings
            .createModelFromFile(environment, pathC, modelPtr)
            .check('LiteRtCreateModelFromFile($_modelPath)');
      } finally {
        calloc.free(pathC);
      }
      model = modelPtr.value;
      calloc.free(modelPtr);

      _refuseMultiInputGraph(bindings, model);

      // Compilation options.
      final optsPtr = calloc<LiteRtOptions>();
      bindings.createOptions(optsPtr).check('LiteRtCreateOptions');
      options = optsPtr.value;
      calloc.free(optsPtr);
      bindings
          .setOptionsHardwareAccelerators(options, _acceleratorFor(backend))
          .check('LiteRtSetOptionsHardwareAccelerators');

      // Compile.
      final compiledPtr = calloc<LiteRtCompiledModel>();
      bindings
          .createCompiledModel(environment, model, options, compiledPtr)
          .check('LiteRtCreateCompiledModel');
      compiled = compiledPtr.value;
      calloc.free(compiledPtr);

      // Auto-detect seqLen + dim from compiled tensor layouts unless pinned.
      int seqLen, dim;
      if (_pinnedSeqLen == null) {
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
      } else {
        seqLen = _pinnedSeqLen;
      }

      if (_pinnedDim == null) {
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
      } else {
        dim = _pinnedDim;
      }

      gemmaLog(
        '[LiteRtEmbeddingForwardPass] loaded: seqLen=$seqLen, dim=$dim, '
        'backend=$backend',
      );

      _environment = environment;
      _model = model;
      _options = options;
      _compiledModel = compiled;
      _inputSequenceLength = seqLen;
      _outputDimension = dim;
    } catch (_) {
      // Free whatever was created, in reverse order, before rethrowing.
      if (compiled != null) bindings.destroyCompiledModel(compiled);
      if (options != null) bindings.destroyOptions(options);
      if (model != null) bindings.destroyModel(model);
      if (environment != null) bindings.destroyEnvironment(environment);
      rethrow;
    }
  }

  /// Run one forward pass over already-tokenized input. [tokenIds] is
  /// right-padded with 0 / truncated to the compiled input's `seqLen` —
  /// tokenization itself (BOS/EOS + prefix) already happened before this is
  /// called (Invariant I1's second half; the first half — tokenize+BOS/EOS —
  /// lives in `flutter_gemma_embeddings`).
  @override
  Future<ForwardResult> run({
    required List<int> tokenIds,
    List<int>? attentionMask,
    List<int>? tokenTypeIds,
  }) async {
    if (_disposed) {
      throw StateError('LiteRtEmbeddingForwardPass is disposed');
    }
    if (_outputDimension == null) {
      throw StateError(
        'LiteRtEmbeddingForwardPass.run() called before load() completed',
      );
    }
    final values = _runForward(tokenIds);
    return ForwardResult(values: values, shape: [1, outputDimension]);
  }

  /// Rejects a graph this backend cannot feed, before paying the compile.
  ///
  /// [_runForward] builds exactly one input tensor — the token ids — and calls
  /// `LiteRtRunCompiledModel` with `numInput: 1`. A BERT-style export that
  /// declares `attention_mask` and `token_type_ids` as separate inputs would
  /// otherwise fail inside the native runtime with a bare status code that
  /// names neither the model nor the reason.
  ///
  /// A supported LiteRT embedder is a single-input export with masking and
  /// pooling baked into the graph, which is what `litert-community` publishes
  /// for EmbeddingGemma and Gecko. The tokenizer is not consulted here: a
  /// multi-input graph is wrong for this backend whichever tokenizer produced
  /// the ids.
  void _refuseMultiInputGraph(LiteRtBindings bindings, LiteRtModel model) {
    final sigPtr = calloc<LiteRtSignature>();
    final countPtr = calloc<Size>();
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
      final namePtr = calloc<Pointer<Utf8>>();
      try {
        for (var i = 0; i < count; i++) {
          if (bindings.getSignatureInputName(sigPtr.value, i, namePtr) == 0 &&
              namePtr.value != nullptr) {
            names.add(namePtr.value.toDartString());
          }
        }
      } finally {
        calloc.free(namePtr);
      }

      throw StateError(
        'LiteRT embedding model "$_modelPath" declares $count inputs'
        '${names.isEmpty ? '' : ' (${names.join(', ')})'} but this backend '
        'feeds exactly one: the token ids. It cannot supply attention_mask or '
        'token_type_ids to a compiled .tflite graph. Supported LiteRT '
        'embedders are single-input exports with masking and pooling baked '
        'into the graph (EmbeddingGemma / Gecko from litert-community). A '
        'multi-input BERT / MiniLM export belongs on the ONNX backend: add '
        'flutter_gemma_onnx, register OnnxEmbeddingBackend, and install the '
        '.onnx export of the same model.',
      );
    } finally {
      calloc.free(sigPtr);
      calloc.free(countPtr);
    }
  }

  List<double> _runForward(List<int> tokens) {
    final bindings = _bindings!;
    final seq = inputSequenceLength!;
    final dim = outputDimension;

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
        inHost[i] = i < tokens.length ? tokens[i] : 0;
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
          .runCompiledModel(_compiledModel!, 0, 1, inBufPtr, 1, outBufPtr)
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
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    final bindings = _bindings;
    if (bindings == null) return; // load() never completed
    if (_compiledModel != null) bindings.destroyCompiledModel(_compiledModel!);
    if (_options != null) bindings.destroyOptions(_options!);
    if (_model != null) bindings.destroyModel(_model!);
    if (_environment != null) bindings.destroyEnvironment(_environment!);
  }
}

/// Top-level factory tear-off — the seam's hard requirement (see
/// `ForwardPassDescriptor.factory`'s doc: it must be a genuine top-level/
/// static tear-off to survive `Isolate.spawn`).
///
/// CPU is hardcoded. Embeddings run on CPU only: the GPU/NPU plumbing exists
/// end-to-end ([EmbeddingBackend] + the LiteRT accelerator flag + the
/// Lock(Read) device→host sync above), but the GPU delegate currently
/// compiles and then returns all-zero vectors (verified on macOS Metal) — so
/// we do NOT route embeddings onto a broken accelerator, even "for symmetry"
/// with inference's configurable backend.
EmbeddingForwardPass createLiteRtEmbeddingForwardPass(String modelPath) =>
    LiteRtEmbeddingForwardPass(modelPath, backend: EmbeddingBackend.cpu);
