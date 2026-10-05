// Real `dart:ffi` implementation of [OrtClient] over the plain ONNX Runtime
// C API (Phase 2 — plain-ORT embedding forward pass, hardened plan Task 2).
//
// Built and used ENTIRELY inside the embedding worker isolate (same
// isolate-affinity rule as `LiteRtEmbeddingForwardPass` in
// `flutter_gemma_litertlm`): the native handles this class holds
// (`OrtEnv`/`OrtSession`/... pointers) cannot cross an isolate boundary, so
// `createOnnxEmbeddingForwardPass`'s `load()` constructs this client fresh
// inside the receiving isolate, never before.
//
// Design: ORT's C API is a struct-of-function-pointers reached via
// `OrtGetApiBase()->GetApi(ORT_API_VERSION)`. Every `OrtStatus*` return goes
// through [_check] — mirrors `LiteRtBindings`'s `.check()` helper — which
// frees the status and throws a [StateError] on failure. Native handles are
// tracked as they're created so a failure partway through `load()` frees
// everything already allocated, in reverse order, instead of leaking it (the
// same pattern `LiteRtEmbeddingForwardPass.load()` uses).

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

import '../ffi/onnxruntime_bindings.g.dart';
import 'ort_client.dart';

/// Env var override for host tests: point directly at a locally-downloaded
/// `libonnxruntime` build without going through Native Assets / the
/// `hook/build.dart` bundle (Task 4). Production app builds never set this —
/// [_openOnnxRuntime] falls through to the platform default names.
const _libraryOverrideEnvVar = 'FLUTTER_GEMMA_ORT_LIBRARY';

ffi.DynamicLibrary _openOnnxRuntime() {
  final override = Platform.environment[_libraryOverrideEnvVar];
  if (override != null && override.isNotEmpty) {
    return ffi.DynamicLibrary.open(override);
  }
  if (Platform.isIOS) {
    // iOS ships no standalone onnxruntime archive: the onnxruntime-genai
    // framework statically links ORT and dynamically exports OrtGetApiBase
    // from the same binary (verified via `nm -gU` on the extracted
    // xcframework slice — see `hook/build.dart`'s iOS branch and
    // `gen_ai_client.dart`'s `_openGenAiLibraries` iOS branch). Resolve it
    // from there instead of a separate CodeAsset.
    //
    // Opening the framework by name works whether or not the inference arm
    // (`GenAiFfiClient`) already loaded it: dlopen of an already-loaded
    // image just bumps its refcount — no double-load, one shared ORT
    // state — and dlopen's loaded-image set is process-wide, so this also
    // resolves correctly from the embedding worker isolate. Falling back to
    // `DynamicLibrary.process()` (guarded by `providesSymbol` so a false hit
    // can't slip past) covers the case where the framework was already
    // loaded under a path this literal name doesn't re-resolve by.
    //
    // The open MUST use the `@executable_path/Frameworks/` anchor — iOS
    // dyld 4 cannot resolve a bare `<name>.framework/<name>` leaf name (same
    // reasoning, and same anchor shape, as
    // `flutter_gemma_litertlm/lib/src/ffi/litert_lm_client.dart`'s
    // `LiteRtLm.framework`/`StreamProxy.framework` opens, and
    // `gen_ai_client.dart`'s `_candidateNames` iOS branch).
    try {
      return ffi.DynamicLibrary.open(
        '@executable_path/Frameworks/onnxruntime-genai.framework/'
        'onnxruntime-genai',
      );
    } catch (_) {}
    final proc = ffi.DynamicLibrary.process();
    if (proc.providesSymbol('OrtGetApiBase')) return proc;
    throw UnsupportedError(
      'Could not resolve OrtGetApiBase on iOS: '
      '@executable_path/Frameworks/onnxruntime-genai.framework/'
      'onnxruntime-genai was not found and the process image does not '
      'already export OrtGetApiBase. Set $_libraryOverrideEnvVar to an '
      'explicit path for host testing — in a real app build iOS resolves '
      'OrtGetApiBase from onnxruntime-genai.framework (see '
      'hook/build.dart\'s iOS branch).',
    );
  }
  if (Platform.isMacOS) {
    final candidates = <String>[
      'libonnxruntime.dylib',
      'onnxruntime.framework/onnxruntime',
      '${Directory.current.path}/native/onnxruntime/prebuilt/macos_arm64/libonnxruntime.dylib',
    ];
    for (final p in candidates) {
      try {
        return ffi.DynamicLibrary.open(p);
      } catch (_) {}
    }
    throw UnsupportedError(
      'libonnxruntime not found in any of: ${candidates.join(", ")} — set '
      '$_libraryOverrideEnvVar to an explicit path for host testing.',
    );
  }
  if (Platform.isAndroid) return ffi.DynamicLibrary.open('libonnxruntime.so');
  if (Platform.isLinux) return ffi.DynamicLibrary.open('libonnxruntime.so');
  if (Platform.isWindows) return ffi.DynamicLibrary.open('onnxruntime.dll');
  throw UnsupportedError(
    'ONNX Runtime is not available on ${Platform.operatingSystem}',
  );
}

// ---------------------------------------------------------------------------
// Dart function-pointer typedefs for the OrtApi struct fields this client
// calls. Each `OrtApi` field is `Pointer<NativeFunction<...>>` — `.asFunction`
// turns it into a callable Dart closure once, cached for the life of the
// client.
// ---------------------------------------------------------------------------

typedef _CreateEnvDart =
    OrtStatusPtr Function(
      int logSeverityLevel,
      ffi.Pointer<ffi.Char> logId,
      ffi.Pointer<ffi.Pointer<OrtEnv>> out,
    );
typedef _CreateSessionOptionsDart =
    OrtStatusPtr Function(ffi.Pointer<ffi.Pointer<OrtSessionOptions>> out);
typedef _SetIntraOpNumThreadsDart =
    OrtStatusPtr Function(ffi.Pointer<OrtSessionOptions> options, int n);
typedef _SetGraphOptDart =
    OrtStatusPtr Function(ffi.Pointer<OrtSessionOptions> options, int level);
typedef _CreateSessionDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtEnv> env,
      ffi.Pointer<ffi.Char> modelPath,
      ffi.Pointer<OrtSessionOptions> options,
      ffi.Pointer<ffi.Pointer<OrtSession>> out,
    );
typedef _SessionGetCountDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtSession> session,
      ffi.Pointer<ffi.Size> out,
    );
typedef _SessionGetNameDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtSession> session,
      int index,
      ffi.Pointer<OrtAllocator> allocator,
      ffi.Pointer<ffi.Pointer<ffi.Char>> value,
    );
typedef _SessionGetTypeInfoDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtSession> session,
      int index,
      ffi.Pointer<ffi.Pointer<OrtTypeInfo>> typeInfo,
    );
typedef _CastTypeInfoDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtTypeInfo> typeInfo,
      ffi.Pointer<ffi.Pointer<OrtTensorTypeAndShapeInfo>> out,
    );
typedef _GetDimensionsCountDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtTensorTypeAndShapeInfo> info,
      ffi.Pointer<ffi.Size> out,
    );
typedef _GetDimensionsDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtTensorTypeAndShapeInfo> info,
      ffi.Pointer<ffi.Int64> dimValues,
      int dimValuesLength,
    );
typedef _GetAllocatorDart =
    OrtStatusPtr Function(ffi.Pointer<ffi.Pointer<OrtAllocator>> out);
typedef _AllocatorFreeDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtAllocator> allocator,
      ffi.Pointer<ffi.Void> p,
    );
typedef _CreateCpuMemoryInfoDart =
    OrtStatusPtr Function(
      int type,
      int memType,
      ffi.Pointer<ffi.Pointer<OrtMemoryInfo>> out,
    );
typedef _CreateTensorDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtMemoryInfo> info,
      ffi.Pointer<ffi.Void> pData,
      int pDataLen,
      ffi.Pointer<ffi.Int64> shape,
      int shapeLen,
      int type,
      ffi.Pointer<ffi.Pointer<OrtValue>> out,
    );
typedef _RunDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtSession> session,
      ffi.Pointer<OrtRunOptions> runOptions,
      ffi.Pointer<ffi.Pointer<ffi.Char>> inputNames,
      ffi.Pointer<ffi.Pointer<OrtValue>> inputs,
      int inputLen,
      ffi.Pointer<ffi.Pointer<ffi.Char>> outputNames,
      int outputNamesLen,
      ffi.Pointer<ffi.Pointer<OrtValue>> outputs,
    );
typedef _GetTensorMutableDataDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtValue> value,
      ffi.Pointer<ffi.Pointer<ffi.Void>> out,
    );
typedef _GetTensorTypeAndShapeDart =
    OrtStatusPtr Function(
      ffi.Pointer<OrtValue> value,
      ffi.Pointer<ffi.Pointer<OrtTensorTypeAndShapeInfo>> out,
    );
typedef _ReleaseDart<T extends ffi.NativeType> =
    void Function(ffi.Pointer<T> p);
typedef _GetErrorMessageDart =
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<OrtStatus> status);

/// Real ONNX Runtime C API implementation of [OrtClient]. NOT safe to share
/// across isolates — see this file's module doc.
class OrtFfiClient implements OrtClient {
  ffi.Pointer<OrtEnv>? _env;
  ffi.Pointer<OrtSessionOptions>? _sessionOptions;
  ffi.Pointer<OrtSession>? _session;
  ffi.Pointer<OrtMemoryInfo>? _cpuMemoryInfo;
  ffi.Pointer<OrtAllocator>? _defaultAllocator; // not owned — do not release

  final _inputNameSet = <String>{};
  String _outputName = '';

  bool _disposed = false;

  // Cached callable function pointers (see the typedefs above).
  late final _CreateEnvDart _createEnv;
  late final _CreateSessionOptionsDart _createSessionOptions;
  late final _SetIntraOpNumThreadsDart _setIntraOpNumThreads;
  late final _SetGraphOptDart _setGraphOptimizationLevel;
  late final _CreateSessionDart _createSession;
  late final _SessionGetCountDart _sessionGetInputCount;
  late final _SessionGetCountDart _sessionGetOutputCount;
  late final _SessionGetNameDart _sessionGetInputName;
  late final _SessionGetNameDart _sessionGetOutputName;
  late final _SessionGetTypeInfoDart _sessionGetInputTypeInfo;
  late final _SessionGetTypeInfoDart _sessionGetOutputTypeInfo;
  late final _CastTypeInfoDart _castTypeInfoToTensorInfo;
  late final _GetDimensionsCountDart _getDimensionsCount;
  late final _GetDimensionsDart _getDimensions;
  late final _GetAllocatorDart _getAllocatorWithDefaultOptions;
  late final _AllocatorFreeDart _allocatorFree;
  late final _CreateCpuMemoryInfoDart _createCpuMemoryInfo;
  late final _CreateTensorDart _createTensorWithDataAsOrtValue;
  late final _RunDart _run;
  late final _GetTensorMutableDataDart _getTensorMutableData;
  late final _GetTensorTypeAndShapeDart _getTensorTypeAndShape;
  late final _ReleaseDart<OrtStatus> _releaseStatus;
  late final _ReleaseDart<OrtEnv> _releaseEnv;
  late final _ReleaseDart<OrtSessionOptions> _releaseSessionOptions;
  late final _ReleaseDart<OrtSession> _releaseSession;
  late final _ReleaseDart<OrtValue> _releaseValue;
  late final _ReleaseDart<OrtTypeInfo> _releaseTypeInfo;
  late final _ReleaseDart<OrtTensorTypeAndShapeInfo>
  _releaseTensorTypeAndShapeInfo;
  late final _ReleaseDart<OrtMemoryInfo> _releaseMemoryInfo;
  late final _GetErrorMessageDart _getErrorMessage;

  int _resolvedApiVersion = ORT_API_VERSION;

  /// The ORT C API version this client actually resolved at construction:
  /// [ORT_API_VERSION] on desktop/Android (standalone ORT 1.27), lower on iOS
  /// where the ORT inside `onnxruntime-genai.framework` predates 1.27.
  int get resolvedApiVersion => _resolvedApiVersion;

  OrtFfiClient() {
    final lib = _openOnnxRuntime();
    final bindings = OnnxRuntimeBindings(lib);
    final apiBase = bindings.OrtGetApiBase();
    if (apiBase == ffi.nullptr) {
      throw StateError('OrtGetApiBase() returned nullptr');
    }
    final getApi = apiBase.ref.GetApi
        .cast<ffi.NativeFunction<ffi.Pointer<OrtApi> Function(ffi.Uint32)>>()
        .asFunction<ffi.Pointer<OrtApi> Function(int)>();
    // Probe DOWN from our compiled ORT_API_VERSION to the newest API the
    // linked onnxruntime actually accepts. Desktop/Android link a standalone
    // ORT 1.27 (API 27) so this matches on the first try; iOS reuses the ORT
    // statically linked inside `onnxruntime-genai.framework`, whose ORT can be
    // OLDER than 1.27 — there `GetApi(27)` returns nullptr and we step down.
    // `OrtApi` is append-only across versions and every function this client
    // binds (CreateEnv/CreateSession/Run/CreateTensorWithDataAsOrtValue/…)
    // exists since API 1, so any non-null `OrtApi*` is safe to use.
    const minOrtApiVersion = 11; // ORT 1.11 floor — far below any bound fn.
    ffi.Pointer<OrtApi> api = ffi.nullptr;
    for (var v = ORT_API_VERSION; v >= minOrtApiVersion; v--) {
      final candidate = getApi(v);
      if (candidate != ffi.nullptr) {
        api = candidate;
        _resolvedApiVersion = v;
        break;
      }
    }
    if (api == ffi.nullptr) {
      throw StateError(
        'OrtApiBase::GetApi returned nullptr for every version in '
        '[$minOrtApiVersion, $ORT_API_VERSION] — the linked onnxruntime build '
        'is older than ORT API $minOrtApiVersion',
      );
    }
    final a = api.ref;

    _createEnv = a.CreateEnv.asFunction<_CreateEnvDart>();
    _createSessionOptions =
        a.CreateSessionOptions.asFunction<_CreateSessionOptionsDart>();
    _setIntraOpNumThreads =
        a.SetIntraOpNumThreads.asFunction<_SetIntraOpNumThreadsDart>();
    _setGraphOptimizationLevel =
        a.SetSessionGraphOptimizationLevel.asFunction<_SetGraphOptDart>();
    _createSession = a.CreateSession.asFunction<_CreateSessionDart>();
    _sessionGetInputCount =
        a.SessionGetInputCount.asFunction<_SessionGetCountDart>();
    _sessionGetOutputCount =
        a.SessionGetOutputCount.asFunction<_SessionGetCountDart>();
    _sessionGetInputName =
        a.SessionGetInputName.asFunction<_SessionGetNameDart>();
    _sessionGetOutputName =
        a.SessionGetOutputName.asFunction<_SessionGetNameDart>();
    _sessionGetInputTypeInfo =
        a.SessionGetInputTypeInfo.asFunction<_SessionGetTypeInfoDart>();
    _sessionGetOutputTypeInfo =
        a.SessionGetOutputTypeInfo.asFunction<_SessionGetTypeInfoDart>();
    _castTypeInfoToTensorInfo =
        a.CastTypeInfoToTensorInfo.asFunction<_CastTypeInfoDart>();
    _getDimensionsCount =
        a.GetDimensionsCount.asFunction<_GetDimensionsCountDart>();
    _getDimensions = a.GetDimensions.asFunction<_GetDimensionsDart>();
    _getAllocatorWithDefaultOptions =
        a.GetAllocatorWithDefaultOptions.asFunction<_GetAllocatorDart>();
    _allocatorFree = a.AllocatorFree.asFunction<_AllocatorFreeDart>();
    _createCpuMemoryInfo =
        a.CreateCpuMemoryInfo.asFunction<_CreateCpuMemoryInfoDart>();
    _createTensorWithDataAsOrtValue =
        a.CreateTensorWithDataAsOrtValue.asFunction<_CreateTensorDart>();
    _run = a.Run.asFunction<_RunDart>();
    _getTensorMutableData =
        a.GetTensorMutableData.asFunction<_GetTensorMutableDataDart>();
    _getTensorTypeAndShape =
        a.GetTensorTypeAndShape.asFunction<_GetTensorTypeAndShapeDart>();
    _releaseStatus = a.ReleaseStatus.asFunction<_ReleaseDart<OrtStatus>>();
    _releaseEnv = a.ReleaseEnv.asFunction<_ReleaseDart<OrtEnv>>();
    _releaseSessionOptions =
        a.ReleaseSessionOptions.asFunction<_ReleaseDart<OrtSessionOptions>>();
    _releaseSession = a.ReleaseSession.asFunction<_ReleaseDart<OrtSession>>();
    _releaseValue = a.ReleaseValue.asFunction<_ReleaseDart<OrtValue>>();
    _releaseTypeInfo =
        a.ReleaseTypeInfo.asFunction<_ReleaseDart<OrtTypeInfo>>();
    _releaseTensorTypeAndShapeInfo =
        a.ReleaseTensorTypeAndShapeInfo.asFunction<
          _ReleaseDart<OrtTensorTypeAndShapeInfo>
        >();
    _releaseMemoryInfo =
        a.ReleaseMemoryInfo.asFunction<_ReleaseDart<OrtMemoryInfo>>();
    _getErrorMessage = a.GetErrorMessage.asFunction<_GetErrorMessageDart>();
  }

  /// Every ORT call returns an `OrtStatus*` — null means success. On
  /// failure, reads the error message, ALWAYS frees the status (mirrors
  /// LiteRT's `.check()`), and throws a [StateError] tagged with [context]
  /// so failures are traceable to the specific ORT call that produced them.
  void _check(OrtStatusPtr status, String context) {
    if (status == ffi.nullptr) return;
    try {
      final msgPtr = _getErrorMessage(status);
      final message = msgPtr == ffi.nullptr
          ? '<no message>'
          : msgPtr.cast<pkg_ffi.Utf8>().toDartString();
      throw StateError('ORT $context failed: $message');
    } finally {
      _releaseStatus(status);
    }
  }

  @override
  Future<OrtIoSpec> load(String modelPath) async {
    ffi.Pointer<OrtEnv>? env;
    ffi.Pointer<OrtSessionOptions>? sessionOptions;
    ffi.Pointer<OrtSession>? session;
    ffi.Pointer<OrtMemoryInfo>? cpuMemoryInfo;
    try {
      final logIdC = 'flutter_gemma_onnx'.toNativeUtf8();
      final envOut = pkg_ffi.calloc<ffi.Pointer<OrtEnv>>();
      try {
        _check(
          _createEnv(
            OrtLoggingLevel.ORT_LOGGING_LEVEL_WARNING.value,
            logIdC.cast(),
            envOut,
          ),
          'CreateEnv',
        );
        env = envOut.value;
      } finally {
        pkg_ffi.calloc.free(logIdC);
        pkg_ffi.calloc.free(envOut);
      }

      final optsOut = pkg_ffi.calloc<ffi.Pointer<OrtSessionOptions>>();
      try {
        _check(_createSessionOptions(optsOut), 'CreateSessionOptions');
        sessionOptions = optsOut.value;
      } finally {
        pkg_ffi.calloc.free(optsOut);
      }
      _check(_setIntraOpNumThreads(sessionOptions, 0), 'SetIntraOpNumThreads');
      _check(
        _setGraphOptimizationLevel(
          sessionOptions,
          GraphOptimizationLevel.ORT_ENABLE_ALL.value,
        ),
        'SetSessionGraphOptimizationLevel',
      );

      // ORT's CreateSession takes the model path as `ORTCHAR_T*`: a narrow
      // UTF-8 `char*` on macOS/Linux/Android, but a WIDE UTF-16 `wchar_t*` on
      // Windows. Passing UTF-8 bytes on Windows makes ORT read them as UTF-16
      // → a mojibake path → "File doesn't exist" — a Windows-only failure the
      // narrow-path hosts never surface (device-caught on real Windows).
      final ffi.Pointer<ffi.Char> modelPathC = Platform.isWindows
          ? modelPath.toNativeUtf16().cast<ffi.Char>()
          : modelPath.toNativeUtf8().cast<ffi.Char>();
      final sessionOut = pkg_ffi.calloc<ffi.Pointer<OrtSession>>();
      try {
        _check(
          _createSession(env, modelPathC, sessionOptions, sessionOut),
          'CreateSession($modelPath)',
        );
        session = sessionOut.value;
      } finally {
        pkg_ffi.calloc.free(modelPathC);
        pkg_ffi.calloc.free(sessionOut);
      }

      final memInfoOut = pkg_ffi.calloc<ffi.Pointer<OrtMemoryInfo>>();
      try {
        _check(
          _createCpuMemoryInfo(
            OrtAllocatorType.OrtArenaAllocator.value,
            OrtMemType.OrtMemTypeDefault.value,
            memInfoOut,
          ),
          'CreateCpuMemoryInfo',
        );
        cpuMemoryInfo = memInfoOut.value;
      } finally {
        pkg_ffi.calloc.free(memInfoOut);
      }

      final allocatorOut = pkg_ffi.calloc<ffi.Pointer<OrtAllocator>>();
      try {
        _check(
          _getAllocatorWithDefaultOptions(allocatorOut),
          'GetAllocatorWithDefaultOptions',
        );
        _defaultAllocator = allocatorOut.value;
      } finally {
        pkg_ffi.calloc.free(allocatorOut);
      }

      final inputNames = _readNames(
        session,
        countFn: _sessionGetInputCount,
        nameFn: _sessionGetInputName,
      );
      final outputCandidateNames = _readNames(
        session,
        countFn: _sessionGetOutputCount,
        nameFn: _sessionGetOutputName,
      );
      if (outputCandidateNames.isEmpty) {
        throw StateError('ONNX model at "$modelPath" declares no outputs');
      }
      final outputIndex = pickOnnxOutputIndex(outputCandidateNames);
      final outputName = outputCandidateNames[outputIndex];

      final inputDims = inputNames.isEmpty
          ? const <int>[]
          : _typeInfoDims(session, index: 0, isInput: true);
      final staticSeqLen = _staticDimension(inputDims, axis: 1);
      final outputDims = _typeInfoDims(
        session,
        index: outputIndex,
        isInput: false,
      );
      final staticDim = _staticDimension(
        outputDims,
        axis: outputDims.length - 1,
      );

      _env = env;
      _sessionOptions = sessionOptions;
      _session = session;
      _cpuMemoryInfo = cpuMemoryInfo;
      _inputNameSet
        ..clear()
        ..addAll(inputNames);
      _outputName = outputName;

      return OrtIoSpec(
        inputNames: inputNames,
        outputName: outputName,
        hasLastHiddenStateOutput: outputName == 'last_hidden_state',
        staticSeqLen: staticSeqLen,
        staticDim: staticDim,
      );
    } catch (_) {
      // Reverse-order teardown on a partial load failure — mirrors
      // LiteRtEmbeddingForwardPass.load()'s catch block.
      if (session != null) _releaseSession(session);
      if (sessionOptions != null) _releaseSessionOptions(sessionOptions);
      if (cpuMemoryInfo != null) _releaseMemoryInfo(cpuMemoryInfo);
      if (env != null) _releaseEnv(env);
      rethrow;
    }
  }

  List<String> _readNames(
    ffi.Pointer<OrtSession> session, {
    required _SessionGetCountDart countFn,
    required _SessionGetNameDart nameFn,
  }) {
    final countOut = pkg_ffi.calloc<ffi.Size>();
    final int count;
    try {
      _check(countFn(session, countOut), 'SessionGet*Count');
      count = countOut.value;
    } finally {
      pkg_ffi.calloc.free(countOut);
    }
    final names = <String>[];
    for (var i = 0; i < count; i++) {
      final nameOut = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>();
      try {
        _check(
          nameFn(session, i, _defaultAllocator!, nameOut),
          'SessionGet*Name($i)',
        );
        final namePtr = nameOut.value;
        names.add(namePtr.cast<pkg_ffi.Utf8>().toDartString());
        _check(
          _allocatorFree(_defaultAllocator!, namePtr.cast()),
          'AllocatorFree(name)',
        );
      } finally {
        pkg_ffi.calloc.free(nameOut);
      }
    }
    return names;
  }

  /// Reads the declared dimensions for input/output [index] — used both for
  /// `staticSeqLen` (input 0, axis 1) and `staticDim` (output, last axis).
  /// Returns an empty list if the tensor is rank<1 or the type info isn't a
  /// tensor (e.g. a sequence/map output) — callers treat that as "unknown,
  /// probe at run time".
  List<int> _typeInfoDims(
    ffi.Pointer<OrtSession> session, {
    required int index,
    required bool isInput,
  }) {
    final typeInfoOut = pkg_ffi.calloc<ffi.Pointer<OrtTypeInfo>>();
    ffi.Pointer<OrtTypeInfo>? typeInfo;
    try {
      final fn = isInput ? _sessionGetInputTypeInfo : _sessionGetOutputTypeInfo;
      _check(fn(session, index, typeInfoOut), 'SessionGet*TypeInfo($index)');
      typeInfo = typeInfoOut.value;

      // CastTypeInfoToTensorInfo returns a pointer INTO typeInfo, not a new
      // object — the header is explicit ("Do not free this value, it will
      // be valid until type_info is freed"). Releasing it independently
      // (as `GetTensorTypeAndShape`'s NEWLY-CREATED result must be, in
      // `_readTensor` below) is a double-free that corrupts the native heap
      // — verified via a real ORT session crashing with SIGABRT inside
      // `ReleaseTypeInfo` right after this call, once `tensorInfo` had
      // already been (wrongly) released here.
      final tensorInfoOut = pkg_ffi
          .calloc<ffi.Pointer<OrtTensorTypeAndShapeInfo>>();
      final ffi.Pointer<OrtTensorTypeAndShapeInfo> tensorInfo;
      try {
        _check(
          _castTypeInfoToTensorInfo(typeInfo, tensorInfoOut),
          'CastTypeInfoToTensorInfo',
        );
        tensorInfo = tensorInfoOut.value;
      } finally {
        pkg_ffi.calloc.free(tensorInfoOut);
      }
      if (tensorInfo == ffi.nullptr) return const [];

      final rankOut = pkg_ffi.calloc<ffi.Size>();
      final int rank;
      try {
        _check(_getDimensionsCount(tensorInfo, rankOut), 'GetDimensionsCount');
        rank = rankOut.value;
      } finally {
        pkg_ffi.calloc.free(rankOut);
      }
      if (rank == 0) return const [];

      final dimsOut = pkg_ffi.calloc<ffi.Int64>(rank);
      try {
        _check(_getDimensions(tensorInfo, dimsOut, rank), 'GetDimensions');
        return [for (var i = 0; i < rank; i++) dimsOut[i]];
      } finally {
        pkg_ffi.calloc.free(dimsOut);
      }
    } finally {
      if (typeInfo != null) _releaseTypeInfo(typeInfo);
      pkg_ffi.calloc.free(typeInfoOut);
    }
  }

  int? _staticDimension(List<int> dims, {required int axis}) {
    if (axis < 0 || axis >= dims.length) return null;
    final d = dims[axis];
    return d > 0 ? d : null; // -1 (or 0) means symbolic/dynamic
  }

  @override
  Future<OrtRunResult> run({
    required List<int> ids,
    List<int>? mask,
    List<int>? typeIds,
  }) async {
    if (_disposed) throw StateError('OrtFfiClient is disposed');
    final session = _session;
    final memInfo = _cpuMemoryInfo;
    if (session == null || memInfo == null) {
      throw StateError('OrtFfiClient.run() called before load() completed');
    }

    final seqLen = ids.length;
    final includeMask =
        mask != null && _inputNameSet.contains('attention_mask');
    final includeTypeIds =
        typeIds != null && _inputNameSet.contains('token_type_ids');

    final tensorNames = <String>[
      'input_ids',
      if (includeMask) 'attention_mask',
      if (includeTypeIds) 'token_type_ids',
    ];
    final ortValues = <ffi.Pointer<OrtValue>>[];
    final int64Buffers = <ffi.Pointer<ffi.Int64>>[];
    final shapeBuffers = <ffi.Pointer<ffi.Int64>>[];
    final nameBuffers = <ffi.Pointer<pkg_ffi.Utf8>>[];
    ffi.Pointer<ffi.Pointer<OrtValue>>? outputsOut;
    ffi.Pointer<ffi.Pointer<ffi.Char>>? inputNamesArray;
    ffi.Pointer<ffi.Pointer<ffi.Char>>? outputNamesArray;

    try {
      ffi.Pointer<OrtValue> makeTensor(List<int> values) {
        final buf = pkg_ffi.calloc<ffi.Int64>(seqLen);
        for (var i = 0; i < seqLen; i++) {
          buf[i] = values[i];
        }
        int64Buffers.add(buf);
        final shape = pkg_ffi.calloc<ffi.Int64>(2);
        shape[0] = 1;
        shape[1] = seqLen;
        shapeBuffers.add(shape);
        final valueOut = pkg_ffi.calloc<ffi.Pointer<OrtValue>>();
        try {
          _check(
            _createTensorWithDataAsOrtValue(
              memInfo,
              buf.cast(),
              seqLen * ffi.sizeOf<ffi.Int64>(),
              shape,
              2,
              ONNXTensorElementDataType
                  .ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
                  .value,
              valueOut,
            ),
            'CreateTensorWithDataAsOrtValue',
          );
          return valueOut.value;
        } finally {
          pkg_ffi.calloc.free(valueOut);
        }
      }

      ortValues.add(makeTensor(ids));
      if (includeMask) ortValues.add(makeTensor(mask));
      if (includeTypeIds) ortValues.add(makeTensor(typeIds));

      inputNamesArray = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>(
        tensorNames.length,
      );
      for (var i = 0; i < tensorNames.length; i++) {
        final c = tensorNames[i].toNativeUtf8();
        nameBuffers.add(c);
        inputNamesArray[i] = c.cast();
      }

      final inputValuesArray = pkg_ffi.calloc<ffi.Pointer<OrtValue>>(
        ortValues.length,
      );
      for (var i = 0; i < ortValues.length; i++) {
        inputValuesArray[i] = ortValues[i];
      }

      final outputNameC = _outputName.toNativeUtf8();
      nameBuffers.add(outputNameC);
      outputNamesArray = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>(1);
      outputNamesArray[0] = outputNameC.cast();

      outputsOut = pkg_ffi.calloc<ffi.Pointer<OrtValue>>(1);
      outputsOut[0] = ffi.nullptr;

      try {
        _check(
          _run(
            session,
            ffi.nullptr,
            inputNamesArray,
            inputValuesArray,
            tensorNames.length,
            outputNamesArray,
            1,
            outputsOut,
          ),
          'Run',
        );
      } finally {
        pkg_ffi.calloc.free(inputValuesArray);
      }

      final outputValue = outputsOut[0];
      if (outputValue == ffi.nullptr) {
        throw StateError('ORT Run produced no output for "$_outputName"');
      }
      try {
        return _readTensor(outputValue);
      } finally {
        _releaseValue(outputValue);
      }
    } finally {
      for (final v in ortValues) {
        _releaseValue(v);
      }
      for (final b in int64Buffers) {
        pkg_ffi.calloc.free(b);
      }
      for (final s in shapeBuffers) {
        pkg_ffi.calloc.free(s);
      }
      for (final n in nameBuffers) {
        pkg_ffi.calloc.free(n);
      }
      if (inputNamesArray != null) pkg_ffi.calloc.free(inputNamesArray);
      if (outputNamesArray != null) pkg_ffi.calloc.free(outputNamesArray);
      if (outputsOut != null) pkg_ffi.calloc.free(outputsOut);
    }
  }

  OrtRunResult _readTensor(ffi.Pointer<OrtValue> value) {
    ffi.Pointer<OrtTensorTypeAndShapeInfo>? shapeInfo;
    try {
      final shapeInfoOut = pkg_ffi
          .calloc<ffi.Pointer<OrtTensorTypeAndShapeInfo>>();
      try {
        _check(
          _getTensorTypeAndShape(value, shapeInfoOut),
          'GetTensorTypeAndShape',
        );
        shapeInfo = shapeInfoOut.value;
      } finally {
        pkg_ffi.calloc.free(shapeInfoOut);
      }

      final rankOut = pkg_ffi.calloc<ffi.Size>();
      final int rank;
      try {
        _check(
          _getDimensionsCount(shapeInfo, rankOut),
          'GetDimensionsCount(output)',
        );
        rank = rankOut.value;
      } finally {
        pkg_ffi.calloc.free(rankOut);
      }

      final dimsOut = pkg_ffi.calloc<ffi.Int64>(rank);
      final List<int> shape;
      try {
        _check(
          _getDimensions(shapeInfo, dimsOut, rank),
          'GetDimensions(output)',
        );
        shape = [for (var i = 0; i < rank; i++) dimsOut[i]];
      } finally {
        pkg_ffi.calloc.free(dimsOut);
      }

      var count = 1;
      for (final d in shape) {
        count *= d;
      }

      final dataOut = pkg_ffi.calloc<ffi.Pointer<ffi.Void>>();
      final Float32List values;
      try {
        _check(_getTensorMutableData(value, dataOut), 'GetTensorMutableData');
        final floatPtr = dataOut.value.cast<ffi.Float>();
        values = Float32List.fromList([
          for (var i = 0; i < count; i++) floatPtr[i],
        ]);
      } finally {
        pkg_ffi.calloc.free(dataOut);
      }

      return OrtRunResult(values: values, shape: shape);
    } finally {
      if (shapeInfo != null) _releaseTensorTypeAndShapeInfo(shapeInfo);
    }
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    if (_session != null) _releaseSession(_session!);
    if (_sessionOptions != null) _releaseSessionOptions(_sessionOptions!);
    if (_cpuMemoryInfo != null) _releaseMemoryInfo(_cpuMemoryInfo!);
    if (_env != null) _releaseEnv(_env!);
    _session = null;
    _sessionOptions = null;
    _cpuMemoryInfo = null;
    _env = null;
  }
}
