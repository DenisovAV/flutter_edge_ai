// Shared LiteRT graph-loading + forward-pass helpers, factored out of
// Matcha's `TtsCore` so the same load/run machinery can drive Qwen3's
// talker/codec graphs too. This is a pure, behavior-preserving extraction:
// `TtsCore` now delegates to [loadLiteRtGraph]/[runLiteRtGraph] instead of
// its own former private `_loadGraph`/`_runGraph` — the tensor-buffer
// create -> run -> lock(Read) -> copy-through-locked-ptr -> unlock ->
// destroy sequence and the partial-failure cleanup are unchanged, only
// renamed and moved. See `tts_core.dart`'s file header for the original
// provenance (a verbatim port of `matcha_synth.dart`'s `runGraph`, FFI-styled
// after `stt_core.dart`).
//
// Generalization over the Matcha-only original: Qwen3's talker `decode`
// signature mixes 58 F32 inputs with 1 I32 input (`input_pos`), and the
// codec graph's input is I32 token ids — so a F32-only `_runGraph` can't be
// reused verbatim. [GraphInput] tags each input with its dtype so
// [runLiteRtGraph] creates the right kind of tensor buffer per input;
// outputs stay F32-only (Qwen3's KV/logits/codec-PCM outputs and Matcha's
// mel/PCM outputs are all f32). The hardcoded signature index `0` is now a
// parameter ([runLiteRtGraph]'s `signatureIndex`) — Matcha call sites keep
// passing `0`.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart' show PreferredBackend;
import 'package:meta/meta.dart' show visibleForTesting;
// Public, native-only bindings library (not the package barrel) — see the
// equivalent comment in `tts_core.dart`/`stt_core.dart` for why this import
// (not the `if (dart.library.ffi)` barrel) is correct in a native-only file.
import 'package:flutter_edge_ai_litertlm/litert_bindings.dart';

/// Maps the public [PreferredBackend] to the LiteRT hardware-accelerator
/// constant. Shared by every speech core (`SttCore`, `TtsCore`,
/// `Qwen3TtsCore`, `InflectTtsCore`) — they used to carry identical private
/// copies of this switch.
int acceleratorFor(PreferredBackend? backend) => switch (backend) {
  PreferredBackend.gpu => kLiteRtHwAcceleratorGpu,
  PreferredBackend.npu => kLiteRtHwAcceleratorNpu,
  PreferredBackend.cpu || null => kLiteRtHwAcceleratorCpu,
};

/// LiteRT's `kLiteRtDelegatePrecisionFp32` (`litert_common.h`).
const int liteRtDelegatePrecisionFp32 = 2;

/// The `gpu_options` payload every speech-to-text graph is compiled with on
/// the GPU. Text-to-speech graphs get none ([configureSpeechAccelerator]).
///
/// fp32. With no options (the accelerator's default, fp16) moonshine-tiny f32
/// returned NaN logits at its first decode step on a Galaxy S23 (Adreno 740);
/// with this payload it transcribed the same text as on the CPU (#747). The
/// precision is what cures it: every payload tried moved the accelerator's
/// logged `kernel_batch_size` from 0 to -1, and one without precision
/// (`enable_infinite_float_capping` alone) still gave NaN.
/// whisper-tiny f32 gave the same text both ways, with no NaN (4.6-5.0 s per
/// 30 s window with the payload over two runs, ~4.7 s without). Parakeet f32 was killed by the system during its load at
/// the default and at fp32; with fp16, madvise and GPU weight conversion it
/// loaded and returned NaN at its first frame. Google's ASR sample
/// (`litert-samples`, speech_recognition) forces fp32 on the GPU for every
/// model it ships. Measured on Adreno 740 only; Metal, WebGPU and Mali are not.
///
/// No `enable_constant_tensors_sharing`: moonshine-tiny f32 aborted the process
/// inside the accelerator (`EMBEDDING_LOOKUP: Unsupported external weights
/// type: 1`) when it was set together with precision fp32, texture weights,
/// madvise and GPU weight conversion; the code path is a float32 embedding
/// table shared as a constant (google-ai-edge/LiteRT-LM#3685). Without it the
/// int8 files did not compile on Adreno 740 (status 3): moonshine-tiny with no
/// options and with `precision = 2` alone, parakeet-ctc with no options.
const String sttGpuOptionsToml = 'precision = $liteRtDelegatePrecisionFp32\n';

/// Identifier LiteRT's GPU accelerator looks its options up by.
const String liteRtGpuOptionsIdentifier = 'gpu_options';

/// `LiteRtBindings.createOpaqueOptions`'s Dart signature.
typedef CreateOpaqueOptions =
    int Function(
      Pointer<Utf8>,
      Pointer<Void>,
      Pointer<NativeFinalizerFunction>,
      Pointer<LiteRtOpaqueOptions>,
    );

/// `LiteRtBindings.addOpaqueOptions`'s Dart signature.
typedef AddOpaqueOptions = int Function(LiteRtOptions, LiteRtOpaqueOptions);

/// `LiteRtBindings.destroyOpaqueOptions`'s Dart signature.
typedef DestroyOpaqueOptions = void Function(LiteRtOpaqueOptions);

/// Appends a `gpu_options` payload holding [toml] to [options].
///
/// The three calls are parameters so a VM test can drive it without LiteRT. A
/// failed create or add throws, so a speech-to-text graph is not compiled for
/// the GPU without its options attached. What the accelerator does with them is
/// LiteRT's: it ignores a payload it cannot find or parse and compiles at its
/// default, with no error (`ml_drift_delegate_create.cc`). The payload is freed
/// on every path that does not hand it to LiteRT.
///
/// [allocator] must be [malloc] or allocate through it: LiteRT frees the
/// payload with [malloc]'s native `free`. Tests pass a recorder over [malloc].
void attachGpuOptions(
  LiteRtOptions options,
  String toml, {
  required CreateOpaqueOptions create,
  required AddOpaqueOptions add,
  required DestroyOpaqueOptions destroy,
  @visibleForTesting Allocator allocator = malloc,
}) {
  final bytes = utf8.encode(toml);
  final payload = allocator<Uint8>(bytes.length + 1);
  payload.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  final identifier = liteRtGpuOptionsIdentifier.toNativeUtf8();
  final opaquePtr = calloc<LiteRtOpaqueOptions>();
  try {
    final created = create(
      identifier,
      payload.cast(),
      malloc.nativeFree,
      opaquePtr,
    );
    if (created != 0) {
      allocator.free(payload);
      created.check('LiteRtCreateOpaqueOptions($liteRtGpuOptionsIdentifier)');
    }
    final opaque = opaquePtr.value;
    final added = add(options, opaque);
    if (added != 0) {
      destroy(opaque);
      added.check('LiteRtAddOpaqueOptions($liteRtGpuOptionsIdentifier)');
    }
  } finally {
    calloc.free(identifier);
    calloc.free(opaquePtr);
  }
}

/// The name an error gives [accelerator]: `cpu`, `gpu` or `npu`.
String acceleratorName(int accelerator) => switch (accelerator) {
  kLiteRtHwAcceleratorGpu => 'gpu',
  kLiteRtHwAcceleratorNpu => 'npu',
  kLiteRtHwAcceleratorCpu => 'cpu',
  _ => 'accelerator $accelerator',
};

/// The error of a failed `LiteRtCreateCompiledModel`: the file at [path], the
/// accelerator it was compiled for and LiteRT's status.
String compiledModelFailureMessage(String path, int accelerator, int status) =>
    'LiteRtCreateCompiledModel($path) failed on the '
    '${acceleratorName(accelerator)} (status=$status)';

/// Throws a [StateError] ([compiledModelFailureMessage]) unless [status] is
/// LiteRT's `kLiteRtStatusOk` (0). On Adreno 740's GPU (#747) an int8 file
/// failed with 3 and Matcha's G2P graph with 504.
void checkCompiledModelStatus(
  int status, {
  required String path,
  required int accelerator,
}) {
  if (status == 0) return;
  throw StateError(compiledModelFailureMessage(path, accelerator, status));
}

/// The compiled model `LiteRtCreateCompiledModel` wrote to [out], given the
/// [status] it returned. [out] is freed on every path, once; a failed status
/// throws ([checkCompiledModelStatus]) without reading [out]. [free] is
/// [calloc]'s `free` (tests pass a recorder over it).
LiteRtCompiledModel takeCompiledModel(
  Pointer<LiteRtCompiledModel> out,
  int status, {
  required String path,
  required int accelerator,
  @visibleForTesting void Function(Pointer<NativeType>)? free,
}) {
  try {
    checkCompiledModelStatus(status, path: path, accelerator: accelerator);
    return out.value;
  } finally {
    (free ?? calloc.free)(out);
  }
}

/// Sets [accelerator] on [options] and, when [fp32OnGpu] is true and it is the
/// GPU, the speech-to-text GPU options ([sttGpuOptionsToml]). Every speech core
/// compiles through this: speech-to-text passes true, text-to-speech false,
/// which leaves its graphs at LiteRT's defaults, as before #747. [context]
/// names the graph in an error.
void configureSpeechAccelerator(
  LiteRtBindings bindings,
  LiteRtOptions options,
  int accelerator, {
  required String context,
  required bool fp32OnGpu,
}) => configureSpeechAcceleratorWith(
  options,
  accelerator,
  context: context,
  fp32OnGpu: fp32OnGpu,
  setAccelerators: bindings.setOptionsHardwareAccelerators,
  create: bindings.createOpaqueOptions,
  add: bindings.addOpaqueOptions,
  destroy: bindings.destroyOpaqueOptions,
);

/// [configureSpeechAccelerator] over the four LiteRT calls it makes, so a VM
/// test can check which graphs get the GPU options.
void configureSpeechAcceleratorWith(
  LiteRtOptions options,
  int accelerator, {
  required String context,
  required bool fp32OnGpu,
  required int Function(LiteRtOptions, int) setAccelerators,
  required CreateOpaqueOptions create,
  required AddOpaqueOptions add,
  required DestroyOpaqueOptions destroy,
}) {
  setAccelerators(
    options,
    accelerator,
  ).check('LiteRtSetOptionsHardwareAccelerators($context)');
  if (fp32OnGpu && accelerator == kLiteRtHwAcceleratorGpu) {
    attachGpuOptions(
      options,
      sttGpuOptionsToml,
      create: create,
      add: add,
      destroy: destroy,
    );
  }
}

/// Resolves [file] from the bundle's filename -> on-disk-path map, failing
/// loud (named by [owner], e.g. `'TtsCore'`) when the bundle doesn't carry
/// it. Shared by the TTS cores — they used to carry per-class private
/// copies differing only in the class name baked into the message.
String artifactPath(
  Map<String, String> artifactPaths,
  String file, {
  required String owner,
}) {
  final path = artifactPaths[file];
  if (path == null) {
    throw StateError('$owner: bundle is missing "$file" in artifactPaths');
  }
  return path;
}

/// Destroys each graph's compiledModel/options/model handles, in creation-
/// reverse order per graph. Shared by every multi-graph core's `dispose` and
/// `load` partial-failure cleanup — they used to repeat this 3-call sequence
/// inline. Does NOT destroy the shared environment; the caller owns that.
void destroyGraphs(LiteRtBindings bindings, Iterable<LoadedGraph> graphs) {
  for (final graph in graphs) {
    bindings.destroyCompiledModel(graph.compiledModel);
    bindings.destroyOptions(graph.options);
    bindings.destroyModel(graph.model);
  }
}

/// One compiled graph's handles (model/options/compiledModel), freed
/// together by the owner's dispose or by [loadLiteRtGraph]'s caller's
/// partial-failure cleanup. Was `TtsCore`'s private `_LoadedGraph`.
class LoadedGraph {
  LoadedGraph(this.model, this.options, this.compiledModel);
  final LiteRtModel model;
  final LiteRtOptions options;
  final LiteRtCompiledModel compiledModel;
}

/// Loads + compiles one `.tflite` graph at [path], mirroring the
/// model/options/compiled sequence `SttCore.load` runs for its single model
/// — generalized so callers (e.g. `TtsCore.load`, the upcoming Qwen3 loader)
/// can call it once per graph. On any failure partway through, frees
/// whatever handles it already created for THIS graph before rethrowing;
/// the caller is responsible for freeing any earlier, already-succeeded
/// graphs + the shared environment. Was `TtsCore`'s private `_loadGraph`.
LoadedGraph loadLiteRtGraph(
  LiteRtBindings bindings,
  LiteRtEnvironment environment,
  String path,
  int accelerator,
) {
  LiteRtModel? model;
  LiteRtOptions? options;
  LiteRtCompiledModel? compiled;
  try {
    final pathC = path.toNativeUtf8();
    final modelPtr = calloc<LiteRtModel>();
    try {
      bindings
          .createModelFromFile(environment, pathC, modelPtr)
          .check('LiteRtCreateModelFromFile($path)');
    } finally {
      calloc.free(pathC);
    }
    model = modelPtr.value;
    calloc.free(modelPtr);

    final optsPtr = calloc<LiteRtOptions>();
    bindings.createOptions(optsPtr).check('LiteRtCreateOptions($path)');
    options = optsPtr.value;
    calloc.free(optsPtr);
    // Text-to-speech graphs only (TtsCore, InflectTtsCore, Qwen3TtsCore): they
    // keep LiteRT's GPU defaults. SttCore.load compiles its own.
    configureSpeechAccelerator(
      bindings,
      options,
      accelerator,
      context: path,
      fp32OnGpu: false,
    );

    final compiledPtr = calloc<LiteRtCompiledModel>();
    final status = bindings.createCompiledModel(
      environment,
      model,
      options,
      compiledPtr,
    );
    compiled = takeCompiledModel(
      compiledPtr,
      status,
      path: path,
      accelerator: accelerator,
    );

    return LoadedGraph(model, options, compiled);
  } catch (_) {
    if (compiled != null) bindings.destroyCompiledModel(compiled);
    if (options != null) bindings.destroyOptions(options);
    if (model != null) bindings.destroyModel(model);
    rethrow;
  }
}

/// One tensor buffer's raw host allocation + its LiteRT wrapper handle,
/// freed together in [runLiteRtGraph]'s `finally`. Mirrors
/// `matcha_synth.dart`'s `_TensorHandle`. Was `TtsCore`'s private
/// `_TensorHandle`.
class TensorHandle {
  TensorHandle(this.raw, this.buffer);
  final Pointer<Uint8> raw;
  final LiteRtTensorBuffer buffer;
}

/// Tagged graph input: pairs a shape with its dtype-specific payload so
/// [runLiteRtGraph] can create the right kind of tensor buffer per input.
/// Matcha's graphs are F32-only ([F32Input] everywhere); Qwen3's talker
/// `decode` signature mixes 58 F32 inputs with 1 I32 input (`input_pos`),
/// and the codec graph's input is I32 token ids.
sealed class GraphInput {
  List<int> get shape;
}

class F32Input extends GraphInput {
  F32Input(this.shape, this.data);
  @override
  final List<int> shape;
  final Float32List data;
}

class I32Input extends GraphInput {
  I32Input(this.shape, this.data);
  @override
  final List<int> shape;
  final Int32List data;
}

/// Generic multi-input/multi-output forward pass over one compiled [graph]
/// at [signatureIndex]. Mirrors `SttCore._encode`/`_decodeLoop`'s tensor-
/// buffer create -> run -> lock(Read) -> copy-through-locked-ptr -> unlock
/// -> destroy sequence, generalized to N inputs / M outputs and to mixed
/// F32/I32 input dtypes via [GraphInput] — this replaces `TtsCore`'s former
/// private `_runGraph` (F32-only, signature index hardcoded to 0). [inputs]
/// and [outputShapes] must list tensors in the model's declared
/// [signatureIndex] argument order. Outputs are always read back as F32.
List<Float32List> runLiteRtGraph(
  LiteRtBindings bindings,
  LiteRtCompiledModel graph,
  int signatureIndex,
  List<GraphInput> inputs,
  List<List<int>> outputShapes,
) {
  final inHandles = <TensorHandle>[];
  final outHandles = <TensorHandle>[];
  try {
    for (final input in inputs) {
      inHandles.add(switch (input) {
        F32Input(:final shape, :final data) => _createTensorBuffer(
          bindings,
          shape,
          kLiteRtElementTypeFloat32,
          data.length,
          (alloc, count) {
            alloc.aligned.cast<Float>().asTypedList(count).setAll(0, data);
          },
        ),
        I32Input(:final shape, :final data) => _createTensorBuffer(
          bindings,
          shape,
          kLiteRtElementTypeInt32,
          data.length,
          (alloc, count) {
            alloc.aligned.cast<Int32>().asTypedList(count).setAll(0, data);
          },
        ),
      });
    }
    for (final shape in outputShapes) {
      outHandles.add(
        _createTensorBuffer(
          bindings,
          shape,
          kLiteRtElementTypeFloat32,
          null,
          null,
        ),
      );
    }

    // Combined arrays are built fresh right before the call and freed
    // right after, mirroring `SttCore._decodeLoop`'s 3-input decode
    // (stt_core.dart:504-527): each buffer was created into its own
    // single-slot pointer above; only `.value` is copied in here.
    final inPtrs = calloc<LiteRtTensorBuffer>(inHandles.length);
    final outPtrs = calloc<LiteRtTensorBuffer>(outHandles.length);
    try {
      for (var i = 0; i < inHandles.length; i++) {
        inPtrs[i] = inHandles[i].buffer;
      }
      for (var i = 0; i < outHandles.length; i++) {
        outPtrs[i] = outHandles[i].buffer;
      }
      bindings
          .runCompiledModel(
            graph,
            signatureIndex,
            inHandles.length,
            inPtrs,
            outHandles.length,
            outPtrs,
          )
          .check('LiteRtRunCompiledModel(signature=$signatureIndex)');
    } finally {
      calloc.free(inPtrs);
      calloc.free(outPtrs);
    }

    // Lock(Read) triggers the device->host sync on GPU/NPU; read each
    // output THROUGH the locked pointer into an owned Float32List copy
    // before unlocking/destroying the buffer — mirrors
    // `SttCore._encode`'s locked-pointer copy (stt_core.dart:322-351).
    final results = <Float32List>[];
    for (var i = 0; i < outHandles.length; i++) {
      final count = outputShapes[i].fold<int>(1, (a, b) => a * b);
      final lockedPtr = calloc<Pointer<Void>>();
      try {
        bindings
            .lockTensorBuffer(
              outHandles[i].buffer,
              lockedPtr,
              kLiteRtTensorBufferLockModeRead,
            )
            .check('LiteRtLockTensorBuffer(out $i)');
        final locked = lockedPtr.value.cast<Float>();
        results.add(Float32List.fromList(locked.asTypedList(count)));
        bindings
            .unlockTensorBuffer(outHandles[i].buffer)
            .check('LiteRtUnlockTensorBuffer(out $i)');
      } finally {
        calloc.free(lockedPtr);
      }
    }
    return results;
  } finally {
    for (final h in inHandles) {
      bindings.destroyTensorBuffer(h.buffer);
      calloc.free(h.raw);
    }
    for (final h in outHandles) {
      bindings.destroyTensorBuffer(h.buffer);
      calloc.free(h.raw);
    }
  }
}

/// Creates a F32 tensor buffer of [shape], optionally seeded with [data].
/// [env] is accepted for signature symmetry with [loadLiteRtGraph] and to
/// leave room for a future host-buffer variant that needs the environment;
/// `LiteRtCreateTensorBufferFromHostMemory` itself does not take one, so it
/// is unused today. Was `TtsCore`'s private `_createF32TensorBuffer`.
TensorHandle createF32TensorBuffer(
  LiteRtBindings bindings,
  LiteRtEnvironment env,
  List<int> shape,
  Float32List? data,
) {
  return _createTensorBuffer(
    bindings,
    shape,
    kLiteRtElementTypeFloat32,
    data?.length,
    data == null
        ? null
        : (alloc, count) {
            alloc.aligned.cast<Float>().asTypedList(count).setAll(0, data);
          },
  );
}

/// Creates an I32 tensor buffer of [shape], optionally seeded with [data].
/// Same as [createF32TensorBuffer] but `elementType =
/// kLiteRtElementTypeInt32` over an [Int32List] payload — used for the
/// talker's `input_pos` and the codec's token-id inputs. [env] is unused
/// today; see [createF32TensorBuffer]'s doc.
TensorHandle createI32TensorBuffer(
  LiteRtBindings bindings,
  LiteRtEnvironment env,
  List<int> shape,
  Int32List? data,
) {
  return _createTensorBuffer(
    bindings,
    shape,
    kLiteRtElementTypeInt32,
    data?.length,
    data == null
        ? null
        : (alloc, count) {
            alloc.aligned.cast<Int32>().asTypedList(count).setAll(0, data);
          },
  );
}

/// Guards every [GraphInput]/[createF32TensorBuffer]/[createI32TensorBuffer]
/// payload: a `data` shorter than [count] (= product of the tensor's shape)
/// would otherwise be silently zero-padded by `setAll` into a
/// wrong-but-not-obviously-wrong tensor, and a longer one would throw a
/// confusing `RangeError` from `setAll` itself instead of naming the actual
/// mismatch. Called from [_createTensorBuffer] itself — BEFORE any native
/// allocation (`allocAligned`/the `type` view) — so a mismatch fails loud
/// with zero native allocation instead of leaking the aligned buffer + type
/// struct that a throw from inside the old write-callback used to leave
/// behind (both were allocated before the `try`/`finally` that frees them).
/// THROWS (not `assert` — asserts are stripped in release builds and this
/// must fail loud in production too).
void _checkPayloadLength(int dataLength, int count) {
  if (dataLength != count) {
    throw ArgumentError(
      'GraphInput payload length $dataLength != product(shape) $count',
    );
  }
}

/// Shared allocate + (optionally) write + wrap-as-tensor-buffer sequence
/// behind [createF32TensorBuffer]/[createI32TensorBuffer]/[runLiteRtGraph]'s
/// per-input dispatch. [elementType] is one of `kLiteRtElementTypeFloat32`/
/// `kLiteRtElementTypeInt32` (both 4-byte elements, so `bytes = count * 4`
/// unconditionally — matches the original F32-only arithmetic byte-for-byte
/// when [elementType] is float32). [dataLength], when non-null (a payload is
/// being written), is validated against `count` (= product of [shape]) via
/// [_checkPayloadLength] BEFORE any native allocation — [writeData], if
/// non-null, is called once with the fresh aligned allocation to copy the
/// caller's payload in AFTER that check passes, so a length mismatch throws
/// with zero native allocation instead of leaking the aligned buffer + the
/// `type` view (both used to be allocated before the length was checked,
/// which sat inside [writeData] itself, past the point either could still
/// be freed on that throw).
TensorHandle _createTensorBuffer(
  LiteRtBindings bindings,
  List<int> shape,
  int elementType,
  int? dataLength,
  void Function(AlignedAlloc alloc, int count)? writeData,
) {
  final count = shape.fold<int>(1, (a, b) => a * b);
  if (dataLength != null) {
    _checkPayloadLength(dataLength, count);
  }
  final bytes = count * 4;
  final type = LiteRtRankedTensorTypeView.calloc()
    ..elementType = elementType
    ..rank = shape.length;
  for (var i = 0; i < shape.length; i++) {
    type.setDimension(i, shape[i]);
  }
  final alloc = allocAligned(bytes);
  writeData?.call(alloc, count);
  final bufPtr = calloc<LiteRtTensorBuffer>();
  // On success alloc.raw is handed off to the caller inside the returned
  // TensorHandle — runLiteRtGraph frees it once the tensor buffer is
  // destroyed. On ANY throw before the return it must be freed here or it
  // leaks native heap permanently (~bytes per failed call) — mirrors
  // SttCore._encode's `returning` flag (stt_core.dart:288).
  var returning = false;
  try {
    bindings
        .createTensorBufferFromHostMemory(
          type.pointer,
          alloc.aligned.cast(),
          bytes,
          nullptr,
          bufPtr,
        )
        .check('CreateTensorBufferFromHostMemory(shape=$shape)');
    returning = true;
    return TensorHandle(alloc.raw, bufPtr.value);
  } finally {
    calloc.free(bufPtr);
    type.free();
    if (!returning) calloc.free(alloc.raw);
  }
}
