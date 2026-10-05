// Opening libLiteRtLm on Android so its exports land in the process-wide
// default symbol search scope — and proving that they did.
//
// WHY THIS EXISTS (#447)
//
// On Android, the FIRST dlopen of a library decides whether its exports are
// reachable through `dlsym(RTLD_DEFAULT)`, and nothing afterwards can change
// that decision:
//
//   * Dart's `DynamicLibrary.open` passes RTLD_LAZY only. POSIX leaves the
//     resulting scope UNSPECIFIED when neither flag is given — bionic and
//     glibc choose RTLD_LOCAL, Apple chooses RTLD_GLOBAL — so on Android the
//     soinfo is filed WITHOUT the RTLD_GLOBAL flag
//   * bionic's `dlsym(RTLD_DEFAULT)` walks only soinfos carrying that flag
//   * re-opening the same file with RTLD_GLOBAL returns the EXISTING soinfo
//     with its refcount bumped and its flags untouched — bionic does not
//     promote (glibc does, which is why Linux never showed this)
//
// So an app that reaches embeddings or speech before generating leaves
// stream_proxy.c's ABI probe blind: `litert_lm_stream_chunk_get_text` resolves
// to NULL, that is read as "pre-v0.15 library", and the 4-arg callback shape
// is registered against a 2-arg caller. Arguments 3 and 4 are then whatever
// x2/x3 happen to hold, and `strdup` runs on the result.
//
// Measured on an API 36 arm64 emulator (`loader_order_447_test.dart` and
// `loader_order_fixed_447_test.dart` in the example's integration tests):
//
//   plain open first                      -> not visible
//   plain open, then RTLD_GLOBAL open     -> STILL not visible, handle non-NULL
//   RTLD_GLOBAL open, then plain open     -> visible
//
// The middle row is why this file verifies rather than trusts. The last row is
// why preventing the bad order is sufficient: a later RTLD_LOCAL open does not
// demote an already-global soinfo.
//
// Both entry points go through this file, and both functions here do the raw
// `DynamicLibrary.open` themselves. That is deliberate: the original bug was a
// bare `DynamicLibrary.open` that reached production because the preload step
// is easy to forget, so there is no longer a version of this operation that
// omits it.
//
// ANDROID ONLY, deliberately. On glibc a later RTLD_GLOBAL dlopen promotes the
// object, so Linux repairs itself as soon as the LLM path runs. Windows has no
// process-wide symbol namespace at all — PE imports bind to (module, symbol)
// pairs and `GetProcAddress` requires an HMODULE, so there is no
// `dlsym(RTLD_DEFAULT)` to be blind: stream_proxy_resolve looks the module up
// by name with GetModuleHandleA. And on Apple
// dlopen defaults to RTLD_GLOBAL, so `dlsym(RTLD_DEFAULT)` searches every
// loaded image.
//
// Note that on Android LiteRT and LiteRT-LM are ONE physical shared object:
// `litert_bindings.dart`'s Android branch opens `libLiteRtLm.so` for the LiteRT
// C API, where its Linux/Windows branches open a separate `libLiteRt.so` /
// `LiteRt.dll`. That is why an embeddings binding has to care about a hazard
// named after the LM library.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Every libLiteRtLm we ship exports this, which is what makes its ABSENCE a
/// usable "this is not our library" signal — distinct from "our library is out
/// of scope".
const _controlSymbol = 'litert_lm_engine_create';

/// The symbol `stream_proxy_probe_abi` actually resolves. Verifying THIS one,
/// rather than a proxy for it, is the point: we ask the question the shim asks
/// and compare its answer against a handle-scoped lookup of the very library
/// we are about to drive.
const _probeSymbol = 'litert_lm_stream_chunk_get_text';

/// The address [name] resolves to through `dlsym(RTLD_DEFAULT)`, or null.
///
/// This is literally `stream_proxy_resolve`'s call. It is answered in the same
/// linker namespace as the shim's, and not by luck: `libStreamProxy.so` is
/// dlopen'd by the Dart VM itself, so bionic files it in the VM's namespace and
/// resolves its `RTLD_DEFAULT` (which is caller-namespace-relative) against the
/// same global group this lookup walks. Move that open to `System.loadLibrary`
/// or a split-APK ClassLoader and the equivalence is gone.
int? _ambientAddress(String name) {
  final p = DynamicLibrary.process();
  return p.providesSymbol(name) ? p.lookup<Void>(name).address : null;
}

int? _handleAddress(DynamicLibrary lib, String name) =>
    lib.providesSymbol(name) ? lib.lookup<Void>(name).address : null;

typedef _LoadGlobalNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _LoadGlobalDart = Pointer<Void> Function(Pointer<Utf8>);

/// Why the exports are, or are not, in the default search scope.
enum _Scope {
  /// The shim's ambient lookup and our handle-scoped lookup agree, so the ABI
  /// it selects is the one we would select. Note this includes BOTH being
  /// absent — a genuine pre-v0.15 library, where the legacy 4-arg shape is
  /// correct. So this means "agrees", not literally "is visible".
  agrees,

  /// The library is loaded and exports the control symbol, but only through a
  /// handle — something opened it locally first, by code outside this package.
  /// Permanent for the process: bionic does not promote.
  poisoned,

  /// The library loaded but does not export the control symbol at all, so this
  /// is not a load-order problem — the bundled artifact is not a libLiteRtLm
  /// this package can drive. Kept apart from [poisoned] because naming the
  /// wrong cause sends the reader hunting for a dlopen that does not exist,
  /// and collapsing two outcomes into one value is what #447 WAS.
  notExported,

  /// The shim's ambient lookup and a handle-scoped lookup of the library we
  /// are about to drive disagree: a DIFFERENT copy of the LiteRT-LM symbols is
  /// in the default scope. The shim would decide the ABI from that copy while
  /// LiteRT-LM streams from ours.
  shadowed,

  /// libStreamProxy.so is not loadable, so the RTLD_GLOBAL preload could not
  /// be attempted at all. Its registration in `hook/build.dart` is conditional
  /// on the file being present in the native bundle, so a partial or stale
  /// cache can produce this.
  proxyUnavailable,
}

/// Loads [soname] with `RTLD_LAZY | RTLD_GLOBAL` via the shipped C helper and
/// reports whether its exports ended up in the default search scope.
///
/// Deliberately silent — each public entry point below phrases its own
/// message, because the same outcome means different things to them.
///
/// Throws when the library cannot be loaded at all, which is fatal for every
/// caller: whatever they wanted to do with it is not going to work.
_Scope _loadAndVerify(String soname, {required String proxyFailureContext}) {
  final _LoadGlobalDart loadGlobal;
  try {
    loadGlobal = DynamicLibrary.open('libStreamProxy.so')
        .lookupFunction<_LoadGlobalNative, _LoadGlobalDart>(
          'stream_proxy_load_global',
        );
  } on Object catch (e) {
    // Not fatal in itself for a handle-scoped caller, so report rather than
    // throw here and let the caller decide. Never silent: this is the one
    // failure that would otherwise look like "the preload ran and did nothing".
    _warn(
      'libStreamProxy.so could not be loaded ($e), so $soname was not '
      'preloaded into the default search scope. $proxyFailureContext This '
      'usually means a partial or stale native cache — `flutter clean` plus '
      'removing the flutter_gemma native cache directory rebuilds it.',
    );
    return _Scope.proxyUnavailable;
  }

  final pathPtr = soname.toNativeUtf8();
  final Pointer<Void> handle;
  try {
    handle = loadGlobal(pathPtr);
  } finally {
    calloc.free(pathPtr);
  }

  if (handle == nullptr) {
    // Two known causes, and the message has to serve both callers — the
    // embeddings/speech binding reaches this too, so it must not prescribe a
    // `.task` model, which provides neither embeddings nor speech.
    throw Exception(
      'Failed to load $soname. On Android the usual causes are: API < 30 '
      '(the library hard-references `pthread_cond_clockwait` / '
      '`sem_clockwait`, which do not exist on API 29 and below — see '
      'https://github.com/DenisovAV/flutter_gemma/issues/265), or a non-arm64 '
      'ABI (current: ${Abi.current()}; only arm64-v8a ships this library — see '
      'https://github.com/DenisovAV/flutter_gemma/issues/250). `.task` '
      'MediaPipe models still run text inference on API < 30 and on other '
      'ABIs; embeddings and speech require arm64 on API 30+.',
    );
  }

  // A non-NULL handle does NOT mean the call did what it was asked to do. If
  // the library was already open, bionic returned the existing soinfo with its
  // original flags, and the load "succeeded" while changing nothing. That is
  // precisely the state #447 shipped in, and only a check can see it.
  //
  // Ask the question the shim will ask, and compare its answer with the same
  // lookup against the library we are about to drive. Asking only "is SOME
  // libLiteRtLm ambient" would pass while a second, older copy of these symbols
  // shadows ours — the shim would then read the accessor from that copy, get
  // NULL, and register the legacy shape. That is #447 again, with the
  // verification reporting success: the exact defect this file exists to close.
  final lib = DynamicLibrary.open(soname);
  if (_handleAddress(lib, _controlSymbol) == null) return _Scope.notExported;

  final handleProbe = _handleAddress(lib, _probeSymbol);
  final ambientProbe = _ambientAddress(_probeSymbol);

  // Both null is a genuine pre-v0.15 library, where the legacy 4-arg shape is
  // the CORRECT choice — an agreeing "no" is still agreement.
  if (handleProbe == ambientProbe) return _Scope.agrees;

  return ambientProbe == null ? _Scope.poisoned : _Scope.shadowed;
}

String _shadowedBy(String soname) =>
    'A different copy of the LiteRT-LM symbols is in the default search scope, '
    'so the stream-callback ABI would be decided from that copy while '
    'generation runs against $soname. Something in the app or a dependency '
    'ships or statically links its own libLiteRtLm.';

String _notExported(String soname) =>
    '$soname loaded but does not export $_controlSymbol. This is not a '
    'load-order problem: the bundled native library is not a libLiteRtLm this '
    'version of flutter_gemma_litertlm can drive. Usually a stale native '
    'cache — remove the flutter_gemma native cache directory and rebuild.';

String _poisonedBy(String soname) =>
    'Something opened $soname with a plain DynamicLibrary.open (or '
    'System.loadLibrary, which is RTLD_NOW without RTLD_GLOBAL) before this '
    'call, and bionic does not promote an already-loaded library, so the '
    'condition is permanent for this process — a Flutter hot restart will '
    'NOT clear it, since linker state outlives the isolate; a full app '
    'restart is required. Load it before flutter_gemma does and with '
    'RTLD_GLOBAL. Note that a Java `System.loadLibrary` cannot request '
    'RTLD_GLOBAL at all, so from Java the only remedy is not to preload it.';

/// Deliberately `print`, and deliberately not `gemmaLog` or `developer.log`.
///
/// `gemmaLog` opens with `if (!kDebugMode) return`, and `dart:developer`'s
/// `log` is compiled out in product mode the same way — so BOTH are silent in
/// release, which is exactly the build where a third-party load-order conflict
/// gets debugged. `print` reaches logcat there. This fires only in an abnormal
/// process state, so it costs nothing in the normal case.
// ignore: avoid_print
void _warn(String message) => print('[LiteRtLm] WARNING: $message');

void _assertAndroid(String fn) {
  if (Platform.isAndroid) return;
  throw UnsupportedError(
    '$fn is Android-only: no other platform needs a default-scope preload — '
    'see the header of litert_default_scope.dart. It also hardcodes the '
    'Android/Linux `libStreamProxy.so` name, which is wrong on Apple '
    '(.dylib in a framework) and Windows (StreamProxy.dll).',
  );
}

/// Opens [soname] for a caller that resolves symbols through the returned
/// handle and does not need them to be ambient.
///
/// That is `LiteRtBindings` and everything in flutter_gemma_speech: they use
/// `_lib.lookupFunction`, which ignores RTLD_GLOBAL entirely, so they work
/// whether or not the preload takes. They come through here to avoid POISONING
/// the process for a later `.litertlm` generation, not because they need the
/// result — so a failed preload logs and carries on rather than breaking an
/// app over a condition it does not depend on.
///
/// The warning goes through [_warn], i.e. bare `print`, for the reason that
/// function documents: `gemmaLog` and `dart:developer`'s `log` are BOTH silent
/// in release, and a third-party load-order conflict is precisely what someone
/// debugs in release.
DynamicLibrary openLiteRtLmPreferringDefaultScope(String soname) {
  _assertAndroid('openLiteRtLmPreferringDefaultScope');
  final scope = _loadAndVerify(
    soname,
    proxyFailureContext:
        'This call site resolves through its own handle and is unaffected, but '
        'a `.litertlm` generation in this process will fail.',
  );
  final tail =
      'This call site does not need them (it resolves through its own '
      'handle), but a `.litertlm` generation in this process will throw.';
  switch (scope) {
    case _Scope.agrees:
    case _Scope.proxyUnavailable: // already reported, with its own cause
      break;
    case _Scope.poisoned:
      _warn(
        '$soname is loaded but its symbols are not in the default search '
        'scope. ${_poisonedBy(soname)} $tail',
      );
    case _Scope.notExported:
      _warn('${_notExported(soname)} $tail');
    case _Scope.shadowed:
      _warn('${_shadowedBy(soname)} $tail');
  }
  return DynamicLibrary.open(soname);
}

/// Opens [soname] for the `.litertlm` inference path, which does need the
/// exports to be ambient, and throws when they are not.
///
/// `stream_proxy.c` resolves the v0.15 stream-chunk accessors with
/// `dlsym(RTLD_DEFAULT)` and reads their absence as "pre-v0.15 library". So
/// continuing past a failed preload would register the 4-arg callback against
/// a 2-arg caller and corrupt generated text rather than fail — which is what
/// #447 was.
DynamicLibrary openLiteRtLmRequiringDefaultScope(String soname) {
  _assertAndroid('openLiteRtLmRequiringDefaultScope');
  final scope = _loadAndVerify(
    soname,
    proxyFailureContext: 'The `.litertlm` inference path needs it.',
  );
  switch (scope) {
    case _Scope.agrees:
      return DynamicLibrary.open(soname);
    case _Scope.poisoned:
      // MUST stay an Error, not an Exception. `initializeFfiRuntime`'s
      // backend-fallback loop in backend_preference.dart catches
      // `on Exception` — an Exception here would be absorbed, retried once
      // per backend, and generation would proceed on the wrong callback ABI,
      // which is #447 itself.
      throw StateError(
        '$soname is loaded but its symbols are not in the default search '
        'scope. ${_poisonedBy(soname)} Continuing would register the wrong '
        'stream-callback ABI and corrupt generated text. See '
        'https://github.com/DenisovAV/flutter_gemma/issues/447',
      );
    case _Scope.shadowed:
      throw StateError(
        '${_shadowedBy(soname)} Continuing would register the wrong '
        'stream-callback ABI and corrupt generated text. See '
        'https://github.com/DenisovAV/flutter_gemma/issues/447',
      );
    case _Scope.notExported:
      // Not a StateError by accident: initializeFfiRuntime's backend-fallback
      // loop catches `on Exception`, so an Exception here would be swallowed
      // and retried per backend while the real cause went unreported.
      throw StateError(_notExported(soname));
    case _Scope.proxyUnavailable:
      throw StateError(
        'libStreamProxy.so is missing or would not load, so $soname could not '
        'be put into the default search scope and the stream-callback ABI '
        'cannot be probed. Both libraries ship in one native archive, so this '
        'points at a partial or stale native cache: run `flutter clean` and '
        'remove the flutter_gemma native cache directory. See '
        'https://github.com/DenisovAV/flutter_gemma/issues/447',
      );
  }
}
