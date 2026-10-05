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

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
// Public, native-only bindings library (not the package barrel) — see the
// equivalent comment in `tts_core.dart`/`stt_core.dart` for why this import
// (not the `if (dart.library.ffi)` barrel) is correct in a native-only file.
import 'package:flutter_gemma_litertlm/litert_bindings.dart';

/// Maps the public [PreferredBackend] to the LiteRT hardware-accelerator
/// constant. Shared by every speech core (`SttCore`, `TtsCore`,
/// `Qwen3TtsCore`, `InflectTtsCore`) — they used to carry identical private
/// copies of this switch.
int acceleratorFor(PreferredBackend? backend) => switch (backend) {
  PreferredBackend.gpu => kLiteRtHwAcceleratorGpu,
  PreferredBackend.npu => kLiteRtHwAcceleratorNpu,
  PreferredBackend.cpu || null => kLiteRtHwAcceleratorCpu,
};

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
    bindings
        .setOptionsHardwareAccelerators(options, accelerator)
        .check('LiteRtSetOptionsHardwareAccelerators($path)');

    final compiledPtr = calloc<LiteRtCompiledModel>();
    bindings
        .createCompiledModel(environment, model, options, compiledPtr)
        .check('LiteRtCreateCompiledModel($path)');
    compiled = compiledPtr.value;
    calloc.free(compiledPtr);

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
