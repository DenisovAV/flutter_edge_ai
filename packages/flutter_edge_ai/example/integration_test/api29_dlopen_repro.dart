// Reproduces issue #265 on Android API 29 (Mi 9T / arm64-v8a).
//
// We don't need a model file — the failure is at dlopen time. The plugin
// path does:
//   1. DynamicLibrary.open('libStreamProxy.so')              -> RTLD_LOCAL
//   2. proxyLib.lookupFunction('stream_proxy_load_global')
//   3. stream_proxy_load_global('libLiteRtLm.so')            -> dlopen RTLD_GLOBAL
//
// On API 29 the plugin throws "Failed to load libLiteRtLm.so with RTLD_GLOBAL"
// but never surfaces the underlying dlerror() string. This test reproduces
// every step explicitly and prints dlerror() at each stage so we know
// exactly which Bionic linker step is rejecting the load.

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

typedef _DlopenC = Pointer<Void> Function(Pointer<Utf8>, Int32);
typedef _DlopenDart = Pointer<Void> Function(Pointer<Utf8>, int);
typedef _DlerrorC = Pointer<Utf8> Function();
typedef _ProxyLoadGlobalC = Pointer<Void> Function(Pointer<Utf8>);

const int _rtldLazy = 0x00001;
const int _rtldNow = 0x00002;
const int _rtldGlobal = 0x00100;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('API 29 dlopen libLiteRtLm.so reproduction', (tester) async {
    expect(Platform.isAndroid, isTrue, reason: 'Android-only test');

    // Lookup dlopen/dlerror via libc handle (DynamicLibrary.process() works
    // on Android because libc is RTLD_GLOBAL in zygote).
    final libc = DynamicLibrary.process();
    final dlopen = libc.lookupFunction<_DlopenC, _DlopenDart>('dlopen');
    final dlerror = libc.lookupFunction<_DlerrorC, _DlerrorC>('dlerror');

    String? readError() {
      final p = dlerror();
      if (p.address == 0) return null;
      return p.toDartString();
    }

    void clearError() => readError();

    // === Stage 1: StreamProxy (small, no deps) ===
    print('[repro] === Stage 1: dlopen libStreamProxy.so RTLD_LAZY ===');
    clearError();
    final spName = 'libStreamProxy.so'.toNativeUtf8();
    final spHandle = dlopen(spName, _rtldLazy);
    calloc.free(spName);
    print(
      '[repro] libStreamProxy handle: ${spHandle.address.toRadixString(16)}',
    );
    if (spHandle.address == 0) {
      final err = readError();
      print('[repro] STAGE 1 FAILED: $err');
      fail('libStreamProxy.so dlopen failed: $err');
    }
    print('[repro] Stage 1 OK');

    // === Stage 2: LiteRtLm with plain RTLD_LAZY (what DynamicLibrary.open does) ===
    print('[repro] === Stage 2: dlopen libLiteRtLm.so RTLD_LAZY (local) ===');
    clearError();
    final lmName = 'libLiteRtLm.so'.toNativeUtf8();
    final localHandle = dlopen(lmName, _rtldLazy);
    print(
      '[repro] libLiteRtLm RTLD_LAZY handle: ${localHandle.address.toRadixString(16)}',
    );
    if (localHandle.address == 0) {
      final err = readError();
      print('[repro] STAGE 2 FAILED (LOCAL): $err');
      // Don't fail yet — also try GLOBAL to see if it's a different error.
    } else {
      print('[repro] Stage 2 OK — local load works');
    }

    // === Stage 3: LiteRtLm with RTLD_GLOBAL (what plugin does, what fails) ===
    // === Stage 2.5: preload UnwindShim from /data/local/tmp ===
    // We push libUnwindShim.so via `adb push` before running the test.
    // It re-exports _Unwind_* symbols from a statically-bundled
    // libunwind.a so the global symbol scope is satisfied for any
    // .so that depends on them on API < 30.
    print('[repro] === Stage 2.5: preload libUnwindShim.so RTLD_GLOBAL ===');
    clearError();
    // Bundled in APK via plugin jniLibs; loaded by basename from app namespace.
    final shimPath = 'libUnwindShim.so'.toNativeUtf8();
    final shimHandle = dlopen(shimPath, _rtldNow | _rtldGlobal);
    calloc.free(shimPath);
    print(
      '[repro] libUnwindShim handle: ${shimHandle.address.toRadixString(16)}',
    );
    if (shimHandle.address == 0) {
      final err = readError();
      print('[repro] STAGE 2.5 FAILED: $err');
      calloc.free(lmName);
      fail('libUnwindShim preload failed: $err');
    }
    print('[repro] Stage 2.5 OK — shim preloaded with RTLD_GLOBAL');

    print(
      '[repro] === Stage 3: dlopen libLiteRtLm.so RTLD_LAZY|RTLD_GLOBAL ===',
    );
    clearError();
    final globalHandle = dlopen(lmName, _rtldLazy | _rtldGlobal);
    print(
      '[repro] libLiteRtLm RTLD_GLOBAL handle: ${globalHandle.address.toRadixString(16)}',
    );
    if (globalHandle.address == 0) {
      final err = readError();
      print('[repro] STAGE 3 FAILED (GLOBAL): $err');
      calloc.free(lmName);
      fail('libLiteRtLm.so dlopen RTLD_GLOBAL failed: $err');
    }
    print('[repro] Stage 3 OK — RTLD_GLOBAL works');

    // === Stage 4: try via stream_proxy_load_global like plugin does ===
    print(
      '[repro] === Stage 4: stream_proxy_load_global("libLiteRtLm.so") ===',
    );
    final proxyLib = DynamicLibrary.open('libStreamProxy.so');
    final loadGlobal = proxyLib
        .lookupFunction<_ProxyLoadGlobalC, _ProxyLoadGlobalC>(
          'stream_proxy_load_global',
        );
    final viaProxy = loadGlobal(lmName);
    print('[repro] via proxy handle: ${viaProxy.address.toRadixString(16)}');
    if (viaProxy.address == 0) {
      final err = readError();
      print('[repro] STAGE 4 FAILED: $err');
      calloc.free(lmName);
      fail('stream_proxy_load_global failed: $err');
    }
    calloc.free(lmName);
    print('[repro] Stage 4 OK');
    print(
      '[repro] === ALL STAGES PASSED on API ${Platform.operatingSystemVersion} ===',
    );
  });
}
