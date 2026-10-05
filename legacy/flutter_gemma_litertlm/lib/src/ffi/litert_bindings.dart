// Dart FFI bindings to the LiteRT C API (https://github.com/google-ai-edge/LiteRT).
//
// We use these to load and run `.tflite` embedding models (Gecko,
// EmbeddingGemma) directly from Dart on all native platforms — replacing
// the per-platform implementations that 0.15.1 and earlier used
// (`com.google.ai.edge.localagents:localagents-rag` JVM lib on Android,
// `TensorFlowLiteC.framework` from Swift on iOS, `libtensorflowlite_c.{dylib,so,dll}`
// via dart:ffi on Desktop). The LiteRT runtime is **already shipped** in
// our native bundle on every platform — it's what `libLiteRtLm`'s
// accelerator dylibs link against — so this binding adds no new
// dependency.
//
// Only the surface needed for a forward pass over an embedding model is
// bound. Reference C headers live at
// https://github.com/google-ai-edge/LiteRT/tree/main/litert/c — search
// for the symbol names below to see full signatures.

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_gemma/core/utils/host_native_library.dart';

import 'package:ffi/ffi.dart';

import 'litert_default_scope.dart';

// ----- Opaque handle typedefs ------------------------------------------------

final class _Opaque extends Opaque {}

typedef LiteRtEnvironment = Pointer<_Opaque>;
typedef LiteRtModel = Pointer<_Opaque>;
typedef LiteRtOptions = Pointer<_Opaque>;
typedef LiteRtCompiledModel = Pointer<_Opaque>;
typedef LiteRtSignature = Pointer<_Opaque>;
typedef LiteRtTensorBuffer = Pointer<_Opaque>;
typedef LiteRtTensorBufferRequirements = Pointer<_Opaque>;

// ----- Constants from litert_common.h ---------------------------------------

const int kLiteRtStatusOk = 0;

/// `LiteRtElementType` values used for embedding pipelines.
const int kLiteRtElementTypeFloat32 = 1;
const int kLiteRtElementTypeInt32 = 2;

/// `LiteRtTensorBufferLockMode` values (litert_common.h).
const int kLiteRtTensorBufferLockModeRead = 0;
const int kLiteRtTensorBufferLockModeWrite = 1;
const int kLiteRtTensorBufferLockModeReadWrite = 2;

/// `LiteRtHwAcceleratorSet` bit flags (litert_common.h). CPU is enough
/// for embedding; GPU/NPU can be wired later.
const int kLiteRtHwAcceleratorNone = 0;
const int kLiteRtHwAcceleratorCpu = 1 << 0;
const int kLiteRtHwAcceleratorGpu = 1 << 1;
const int kLiteRtHwAcceleratorNpu = 1 << 2;

/// Host memory alignment required by `LiteRtCreateTensorBufferFromHostMemory`
/// (see `LITERT_HOST_MEMORY_BUFFER_ALIGNMENT` in litert_tensor_buffer_types.h).
const int kLiteRtHostMemoryAlignment = 64;

const int kLiteRtMaxRank = 8;

// ----- LiteRtLayout (litert_layout.h) ----------------------------------------
//
// typedef struct {
//   unsigned int rank : 7;
//   unsigned int has_strides : 1;
//   int32_t dimensions[8];
//   uint32_t strides[8];
// } LiteRtLayout;
//
// One binary layout on every compiler: `dimensions[]` at byte offset 4,
// 68 bytes in total. Until LiteRT d84656955 `has_strides` was a `bool`, and
// MSVC gave it a storage unit of its own, which moved `dimensions[]` to offset
// 8 on Windows (google-ai-edge/LiteRT#7459). Every bundle we ship is built
// from a LiteRT pin after that fix, so a separate MSVC mirror would put every
// shape 4 bytes off; upstream now static_asserts the shared layout.
//
// FFI has no bit-field support, so rank + has_strides are a single `Uint8`
// the caller composes (low 7 bits = rank, high bit = has_strides).

/// LiteRtLayout, identical on every platform. The name predates the upstream
/// fix above. Read [LiteRtLayoutView] for accessors.
final class LiteRtLayoutPosix extends Struct {
  @Uint8()
  external int rankAndHasStrides;
  // ignore: unused_field
  @Uint8()
  external int pad0;
  // ignore: unused_field
  @Uint8()
  external int pad1;
  // ignore: unused_field
  @Uint8()
  external int pad2;

  @Array(8)
  external Array<Int32> dimensions;

  @Array(8)
  external Array<Uint32> strides;
}

/// View over a `LiteRtLayout*` filled in by the C API.
class LiteRtLayoutView {
  LiteRtLayoutView._(this._layout);

  /// Allocate a zeroed layout. Free with [free].
  factory LiteRtLayoutView.calloc() =>
      LiteRtLayoutView._(calloc<LiteRtLayoutPosix>());

  final Pointer<LiteRtLayoutPosix> _layout;

  /// Pass to LiteRt accessor functions (e.g. `getInputTensorLayout`).
  Pointer<Void> get pointer => _layout.cast<Void>();

  int get rank => _layout.ref.rankAndHasStrides & 0x7f;

  int dimension(int i) => _layout.ref.dimensions[i];

  void free() => calloc.free(_layout);
}

// ----- LiteRtRankedTensorType (litert_model_types.h) -------------------------
//
// struct LiteRtRankedTensorType {
//   LiteRtElementType element_type;
//   LiteRtLayout layout;
// };
//
// Embeds `LiteRtLayout`, so it shares the single layout described above:
// 72 bytes on every platform.

final class LiteRtRankedTensorTypePosix extends Struct {
  @Int32()
  external int elementType;
  external LiteRtLayoutPosix layout;
}

/// Builder for `LiteRtRankedTensorType*`: element type, rank, dimensions.
class LiteRtRankedTensorTypeView {
  LiteRtRankedTensorTypeView._(this._type);

  /// Allocate a zeroed ranked tensor type. Free with [free].
  factory LiteRtRankedTensorTypeView.calloc() =>
      LiteRtRankedTensorTypeView._(calloc<LiteRtRankedTensorTypePosix>());

  final Pointer<LiteRtRankedTensorTypePosix> _type;

  /// Pass to LiteRt functions that consume a `LiteRtRankedTensorType*`.
  Pointer<Void> get pointer => _type.cast<Void>();

  set elementType(int value) => _type.ref.elementType = value;

  /// Set rank (1..127) and clear `has_strides`.
  set rank(int value) => _type.ref.layout.rankAndHasStrides = value & 0x7f;

  void setDimension(int i, int value) => _type.ref.layout.dimensions[i] = value;

  void free() => calloc.free(_type);
}

// ----- Dynamic library resolution --------------------------------------------

/// macOS-only fallbacks for `libLiteRtLm.dylib`, used when there is no app
/// bundle to resolve `LiteRtLm.framework` from — i.e. `flutter test` on the
/// host. Never reached inside a shipped app.
///
/// This used to be a single path built as
/// `${Directory.current.path}/native/litert_lm/prebuilt/...`, which is only
/// right when the current directory happens to BE flutter_gemma_litertlm.
/// `flutter_gemma_speech` binds these same
/// symbols, and running its suite from its own package directory pointed
/// the lookup at a `native/` tree that does not exist there. The resulting
/// error named a path and said "not found", so it read as "the native library
/// was never built" rather than "I looked in the wrong place" — and 9 speech
/// tests sat red under that misreading. So: walk UP to the workspace root
/// instead of assuming it.
///
/// The ordering rules — cache before local build, walk up rather than assume —
/// and the incidents behind them now live in ONE place, core's
/// host_native_library.dart, because this search had been written three times
/// (here, and twice in rag_sqlite's tests) and the copies had drifted.
List<String> _devLiteRtLmCandidates() {
  // Guarded rather than trusted: hostNativeDirName() is null on iOS, and the
  // relative paths below interpolate it, so an unguarded call would build
  // `.../prebuilt/null/libLiteRtLm.dylib`. Unreachable today — _openLiteRt
  // throws for iOS before getting here — but a comment is the only thing
  // keeping that true, and comments do not fail.
  final hostDir = hostNativeDirName();
  if (hostDir == null) return const [];
  return _candidatesFor(hostDir);
}

List<String> _candidatesFor(String hostDir) => hostNativeLibraryCandidates(
  // Reached only from the macOS branch of _openLiteRt (iOS throws before it),
  // so the host names the shared helper computes are the macOS ones.
  libFileName: hostNativeLibraryFileName('LiteRtLm'),
  // LiteRT uses the FLAT cache layout: <cacheBase>/<host>/, no namespace.
  relativePaths: [
    'packages/flutter_gemma_litertlm/native/litert_lm/prebuilt/'
        '$hostDir/${hostNativeLibraryFileName('LiteRtLm')}',
    'native/litert_lm/prebuilt/'
        '$hostDir/${hostNativeLibraryFileName('LiteRtLm')}',
  ],
);

DynamicLibrary _openLiteRt() {
  if (Platform.isMacOS || Platform.isIOS) {
    // libLiteRt is statically linked into LiteRtLm.framework on Apple
    // platforms; both LiteRtLm and LiteRt symbols are exported from the
    // same dylib. The `@executable_path/../Frameworks/...` path resolves
    // at runtime; outside an app bundle we fall back to a dev prebuilt.
    const bundled = 'LiteRtLm.framework/LiteRtLm';
    try {
      return DynamicLibrary.open(bundled);
    } catch (_) {}

    // iOS always resolves the bundled framework; it has no dev checkout and no
    // ~/Library/Caches. Offering it macOS .dylib paths would make the failure
    // message actively misleading on the one occasion someone reads it.
    if (Platform.isIOS) {
      throw UnsupportedError(
        'LiteRtLm.framework/LiteRtLm did not load. On iOS this is the only '
        'candidate — the framework is missing from the app bundle.',
      );
    }

    final tried = <String>[bundled];
    for (final p in _devLiteRtLmCandidates()) {
      tried.add(p);
      // Existence-check first so the message below can tell "no such file"
      // from "found it but it would not load"...
      if (!File(p).existsSync()) continue;
      try {
        return DynamicLibrary.open(p);
      } catch (_) {
        // ...and keep going when a candidate exists but will not load — wrong
        // arch, missing companion, stale build. Without this the first
        // existing-but-broken candidate aborts the search and the remaining
        // ones, including the version-validated hook cache, are never tried.
      }
    }
    throw UnsupportedError(
      'LiteRtLm framework/dylib not found or would not load. Tried (cwd: '
      '${Directory.current.path}): ${tried.join(", ")}',
    );
  }
  if (Platform.isAndroid) {
    // #447: this is the embeddings/speech entry point, and on Android it may
    // well be the FIRST thing in the process to open libLiteRtLm — whichever
    // path gets there first decides for good whether the library's exports are
    // reachable through dlsym(RTLD_DEFAULT). Opening it plainly here left the
    // LLM path's stream-ABI probe permanently blind. Load it into the default
    // scope first; the handle-scoped open below is then just a handle.
    //
    // Best effort on purpose. This binding resolves everything through its own
    // handle, so it works whether or not the symbols are ambient — and a
    // speech-only or embeddings-only app must not be broken by a condition it
    // does not depend on. The point of calling this here is to be FIRST, so a
    // later `.litertlm` generation is not poisoned.
    // Guard the ABI before touching any native library. LiteRT-LM ships
    // android_arm64 only, so on an x86_64 emulator or armeabi-v7a device
    // nothing is bundled — and the first thing the scope helper opens is
    // libStreamProxy, so without this the failure names a library the caller
    // has never heard of instead of saying "wrong ABI". Mirrors the guard in
    // litert_lm_client.dart's Android branch.
    if (Abi.current() != Abi.androidArm64) {
      throw UnsupportedError(
        'flutter_gemma embeddings and speech require an arm64-v8a Android '
        'device (got ${Abi.current()}). LiteRT-LM ships no other Android ABI. '
        'MediaPipe `.task` text inference still works on this ABI.',
      );
    }
    return openLiteRtLmPreferringDefaultScope('libLiteRtLm.so');
  }
  // Linux and Windows need no equivalent: glibc promotes an already-loaded
  // object when a later dlopen asks for RTLD_GLOBAL, and PE modules are
  // reachable through the loaded-module list regardless. See the header of
  // litert_default_scope.dart.
  if (Platform.isLinux) return DynamicLibrary.open('libLiteRt.so');
  if (Platform.isWindows) return DynamicLibrary.open('LiteRt.dll');
  throw UnsupportedError(
    'LiteRT is not available on ${Platform.operatingSystem}',
  );
}

// ----- Bindings --------------------------------------------------------------

/// Minimal C-API surface for running an embedding forward pass.
///
/// Open once per process via [LiteRtBindings.open]; the underlying
/// `DynamicLibrary` is opaque and process-cached by dart:ffi.
class LiteRtBindings {
  LiteRtBindings._(this._lib);
  factory LiteRtBindings.open() => LiteRtBindings._(_openLiteRt());

  final DynamicLibrary _lib;

  // Environment.

  late final createEnvironment = _lib
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>, Pointer<LiteRtEnvironment>),
        int Function(int, Pointer<Void>, Pointer<LiteRtEnvironment>)
      >('LiteRtCreateEnvironment');

  late final destroyEnvironment = _lib
      .lookupFunction<
        Void Function(LiteRtEnvironment),
        void Function(LiteRtEnvironment)
      >('LiteRtDestroyEnvironment');

  // Model.

  // LiteRT (622f1f3c / LiteRT-LM v0.14.0) added a leading LiteRtEnvironment
  // parameter to LiteRtCreateModelFromFile. Calling the old 2-arg form against
  // the new lib read `filename` as `environment` → status=500 on every load.
  late final createModelFromFile = _lib
      .lookupFunction<
        Int32 Function(LiteRtEnvironment, Pointer<Utf8>, Pointer<LiteRtModel>),
        int Function(LiteRtEnvironment, Pointer<Utf8>, Pointer<LiteRtModel>)
      >('LiteRtCreateModelFromFile');

  // Signature introspection. Used by the embedding forward pass to refuse a
  // graph it cannot feed: it supplies exactly one input tensor (the token
  // ids), so a multi-input BERT-style export has to be rejected at load
  // rather than dying inside LiteRtRunCompiledModel with a bare status code.
  // Exported by libLiteRtLm on all five platforms (verified with nm/objdump
  // against the native-v0.17.0-a archives).
  late final getModelSignature = _lib
      .lookupFunction<
        Int32 Function(LiteRtModel, Size, Pointer<LiteRtSignature>),
        int Function(LiteRtModel, int, Pointer<LiteRtSignature>)
      >('LiteRtGetModelSignature');

  late final getNumSignatureInputs = _lib
      .lookupFunction<
        Int32 Function(LiteRtSignature, Pointer<Size>),
        int Function(LiteRtSignature, Pointer<Size>)
      >('LiteRtGetNumSignatureInputs');

  late final getSignatureInputName = _lib
      .lookupFunction<
        Int32 Function(LiteRtSignature, Size, Pointer<Pointer<Utf8>>),
        int Function(LiteRtSignature, int, Pointer<Pointer<Utf8>>)
      >('LiteRtGetSignatureInputName');

  late final destroyModel = _lib
      .lookupFunction<Void Function(LiteRtModel), void Function(LiteRtModel)>(
        'LiteRtDestroyModel',
      );

  // Compilation options.

  late final createOptions = _lib
      .lookupFunction<
        Int32 Function(Pointer<LiteRtOptions>),
        int Function(Pointer<LiteRtOptions>)
      >('LiteRtCreateOptions');

  late final destroyOptions = _lib
      .lookupFunction<
        Void Function(LiteRtOptions),
        void Function(LiteRtOptions)
      >('LiteRtDestroyOptions');

  late final setOptionsHardwareAccelerators = _lib
      .lookupFunction<
        Int32 Function(LiteRtOptions, Int32),
        int Function(LiteRtOptions, int)
      >('LiteRtSetOptionsHardwareAccelerators');

  // Compiled model.

  late final createCompiledModel = _lib
      .lookupFunction<
        Int32 Function(
          LiteRtEnvironment,
          LiteRtModel,
          LiteRtOptions,
          Pointer<LiteRtCompiledModel>,
        ),
        int Function(
          LiteRtEnvironment,
          LiteRtModel,
          LiteRtOptions,
          Pointer<LiteRtCompiledModel>,
        )
      >('LiteRtCreateCompiledModel');

  late final destroyCompiledModel = _lib
      .lookupFunction<
        Void Function(LiteRtCompiledModel),
        void Function(LiteRtCompiledModel)
      >('LiteRtDestroyCompiledModel');

  late final runCompiledModel = _lib
      .lookupFunction<
        Int32 Function(
          LiteRtCompiledModel,
          IntPtr,
          IntPtr,
          Pointer<LiteRtTensorBuffer>,
          IntPtr,
          Pointer<LiteRtTensorBuffer>,
        ),
        int Function(
          LiteRtCompiledModel,
          int,
          int,
          Pointer<LiteRtTensorBuffer>,
          int,
          Pointer<LiteRtTensorBuffer>,
        )
      >('LiteRtRunCompiledModel');

  late final getInputBufferRequirements = _lib
      .lookupFunction<
        Int32 Function(
          LiteRtCompiledModel,
          IntPtr,
          IntPtr,
          Pointer<LiteRtTensorBufferRequirements>,
        ),
        int Function(
          LiteRtCompiledModel,
          int,
          int,
          Pointer<LiteRtTensorBufferRequirements>,
        )
      >('LiteRtGetCompiledModelInputBufferRequirements');

  late final getOutputBufferRequirements = _lib
      .lookupFunction<
        Int32 Function(
          LiteRtCompiledModel,
          IntPtr,
          IntPtr,
          Pointer<LiteRtTensorBufferRequirements>,
        ),
        int Function(
          LiteRtCompiledModel,
          int,
          int,
          Pointer<LiteRtTensorBufferRequirements>,
        )
      >('LiteRtGetCompiledModelOutputBufferRequirements');

  // LiteRtStatus LiteRtGetCompiledModelInputTensorLayout(
  //     LiteRtCompiledModel, LiteRtParamIndex signature_index,
  //     LiteRtParamIndex input_index, LiteRtLayout* layout);
  //
  // Layout pointer is opaque on our side — the caller picks the right
  // POSIX/MSVC backing struct via [LiteRtLayoutView].
  late final getInputTensorLayout = _lib
      .lookupFunction<
        Int32 Function(LiteRtCompiledModel, IntPtr, IntPtr, Pointer<Void>),
        int Function(LiteRtCompiledModel, int, int, Pointer<Void>)
      >('LiteRtGetCompiledModelInputTensorLayout');

  // LiteRtStatus LiteRtGetCompiledModelOutputTensorLayouts(
  //     LiteRtCompiledModel, LiteRtParamIndex signature_index,
  //     size_t num_layouts, LiteRtLayout* layouts, bool update_allocation);
  late final getOutputTensorLayouts = _lib
      .lookupFunction<
        Int32 Function(
          LiteRtCompiledModel,
          IntPtr,
          IntPtr,
          Pointer<Void>,
          Bool,
        ),
        int Function(LiteRtCompiledModel, int, int, Pointer<Void>, bool)
      >('LiteRtGetCompiledModelOutputTensorLayouts');

  // Tensor buffer.

  // Tensor type is opaque on our side — fill it via
  // [LiteRtRankedTensorTypeView] which picks the right POSIX/MSVC backing.
  late final createTensorBufferFromHostMemory = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          IntPtr,
          Pointer<Void>,
          Pointer<LiteRtTensorBuffer>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<Void>,
          Pointer<LiteRtTensorBuffer>,
        )
      >('LiteRtCreateTensorBufferFromHostMemory');

  late final destroyTensorBuffer = _lib
      .lookupFunction<
        Void Function(LiteRtTensorBuffer),
        void Function(LiteRtTensorBuffer)
      >('LiteRtDestroyTensorBuffer');

  late final lockTensorBuffer = _lib
      .lookupFunction<
        Int32 Function(LiteRtTensorBuffer, Pointer<Pointer<Void>>, Int32),
        int Function(LiteRtTensorBuffer, Pointer<Pointer<Void>>, int)
      >('LiteRtLockTensorBuffer');

  late final unlockTensorBuffer = _lib
      .lookupFunction<
        Int32 Function(LiteRtTensorBuffer),
        int Function(LiteRtTensorBuffer)
      >('LiteRtUnlockTensorBuffer');
}

// ----- Status / alignment helpers --------------------------------------------

/// Throws if a LiteRT C call returned a non-OK status code.
extension LiteRtStatusX on int {
  void check(String context) {
    if (this != kLiteRtStatusOk) {
      throw StateError('LiteRT call failed: $context (status=$this)');
    }
  }
}

/// Pair of `(raw, aligned)` pointers returned by [allocAligned].
class AlignedAlloc {
  AlignedAlloc(this.raw, this.aligned);

  /// The actual `calloc`-owned allocation. Free with `calloc.free(raw)`.
  final Pointer<Uint8> raw;

  /// A pointer into `raw` aligned to the requested boundary. Use this for
  /// the LiteRT C API; do not free it directly.
  final Pointer<Uint8> aligned;
}

/// Allocate `bytes` of host memory and return a [AlignedAlloc] whose
/// `.aligned` pointer is aligned to [align] bytes (default 64, the
/// `LITERT_HOST_MEMORY_BUFFER_ALIGNMENT` value).
///
/// Dart's `calloc` returns at most 16-byte aligned memory on most ABIs,
/// which is below LiteRT's 64-byte requirement. We over-allocate by
/// `align + sizeof(void*)` and round the pointer up.
AlignedAlloc allocAligned(int bytes, {int align = kLiteRtHostMemoryAlignment}) {
  final raw = calloc<Uint8>(bytes + align + sizeOf<IntPtr>());
  final mask = align - 1;
  final aligned = Pointer<Uint8>.fromAddress((raw.address + align) & ~mask);
  return AlignedAlloc(raw, aligned);
}
