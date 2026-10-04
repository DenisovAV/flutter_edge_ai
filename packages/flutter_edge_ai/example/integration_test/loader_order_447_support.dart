// Shared mechanism for the two #447 load-order tests.
//
// Both tests ask the same question — "can dlsym(RTLD_DEFAULT) see
// libLiteRtLm's exports?" — and differ ONLY in the order the library is first
// opened. Keeping the mechanism in one place is the point: if the two tests
// resolved symbols differently, a disagreement between them would prove
// nothing about load order.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// The v0.15 chunk accessor stream_proxy.c probes for. Its absence is read as
/// "old ABI" and selects the 4-arg callback shape.
const probeSymbol = 'litert_lm_stream_chunk_get_text';

/// Present in EVERY version of the library — a control for "is it loaded at
/// all", so a failure to see [probeSymbol] can be attributed to visibility
/// rather than to a library that predates the accessors.
const controlSymbol = 'litert_lm_engine_create';

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);
typedef _LoadGlobalNative = Pointer<Void> Function(Pointer<Uint8>);
typedef _LoadGlobalDart = Pointer<Void> Function(Pointer<Uint8>);

/// Whether [soname] is mapped into this process AT ALL, regardless of scope.
///
/// The obvious clean-process check — "the control symbol is not ambient" —
/// cannot tell "nothing loaded it" from "something loaded it LOCALLY", and the
/// second is the poisoned state this whole file is about. A test that treats
/// them as one reports a pass while measuring someone else's poisoning: the
/// same two-outcomes-one-value defect as #447 itself, reproduced in the
/// instrument.
///
/// /proc/self/maps distinguishes them. A process can always read its own, and
/// the path shows up whether the .so was extracted to the app's lib dir or
/// mapped uncompressed straight out of the APK.
bool mappedInProcess(String soname) =>
    File('/proc/self/maps').readAsStringSync().contains(soname);

/// dlsym(RTLD_DEFAULT, name) — literally the call stream_proxy_resolve makes.
///
/// DynamicLibrary.process() IS RTLD_DEFAULT and providesSymbol is dlsym on it,
/// which is what makes this property observable from pure Dart with no model,
/// no engine and no generation.
bool globallyVisible(String name) =>
    DynamicLibrary.process().providesSymbol(name);

/// Calls the SHIPPED helper rather than a hand-rolled dlopen.
///
/// The question these tests answer is what PRODUCTION code does, and
/// litert_lm_client.dart's Android arm reaches libLiteRtLm through exactly
/// this export. A local reimplementation could pass while the real one fails.
///
/// libStreamProxy.so is safe to open first: its only DT_NEEDED entries are
/// libdl and libc (verified with llvm-readelf), so opening it cannot drag
/// libLiteRtLm into the process ahead of the ordering under test.
Pointer<Void> loadGlobal(String soname) {
  final proxy = DynamicLibrary.open('libStreamProxy.so');
  final fn = proxy.lookupFunction<_LoadGlobalNative, _LoadGlobalDart>(
    'stream_proxy_load_global',
  );
  final path = _cstr(soname);
  try {
    return fn(path);
  } finally {
    _free(path);
  }
}

// package:ffi is not a dependency of this example, and adding one for a test
// would be a pubspec change; libc's own malloc/free are reachable through
// RTLD_DEFAULT on every Android process.
Pointer<Uint8> _cstr(String s) {
  final malloc = DynamicLibrary.process()
      .lookupFunction<_MallocNative, _MallocDart>('malloc');
  final units = utf8.encode(s);
  final p = malloc(units.length + 1);
  p.asTypedList(units.length + 1)
    ..setRange(0, units.length, units)
    ..[units.length] = 0;
  return p;
}

void _free(Pointer<Uint8> p) =>
    DynamicLibrary.process().lookupFunction<_FreeNative, _FreeDart>('free')(p);

/// Positive control for [globallyVisible].
///
/// Every assertion about poisoning expects `false`, so a [globallyVisible] that
/// simply never worked would make a whole file pass while measuring nothing.
/// libc is always in the default scope, so this must be true for any negative
/// result below to carry meaning.
void expectLookupWorks() {
  if (!globallyVisible('malloc')) {
    throw StateError(
      'dlsym(RTLD_DEFAULT) cannot see libc malloc — the measurement apparatus '
      'is broken, so every negative result in this file is meaningless rather '
      'than informative',
    );
  }
}
