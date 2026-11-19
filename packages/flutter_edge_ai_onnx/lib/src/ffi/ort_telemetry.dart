// Microsoft's telemetry switch shared by the ORT-GenAI generation client and
// the plain ONNX Runtime embedding client.
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkg_ffi;

typedef _SetenvNative =
    ffi.Int32 Function(
      ffi.Pointer<pkg_ffi.Utf8>,
      ffi.Pointer<pkg_ffi.Utf8>,
      ffi.Int32,
    );
typedef _SetenvDart =
    int Function(ffi.Pointer<pkg_ffi.Utf8>, ffi.Pointer<pkg_ffi.Utf8>, int);
typedef _GetenvNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf8>);
typedef _GetenvDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf8>);
typedef _WputenvSNative =
    ffi.Int32 Function(ffi.Pointer<pkg_ffi.Utf16>, ffi.Pointer<pkg_ffi.Utf16>);
typedef _WputenvSDart =
    int Function(ffi.Pointer<pkg_ffi.Utf16>, ffi.Pointer<pkg_ffi.Utf16>);
typedef _WgetenvNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf16>);
typedef _WgetenvDart =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf16>);

/// The variable ONNX Runtime and ORT-GenAI read to turn Microsoft's 1DS
/// telemetry off.
const _telemetryVariable = 'ORT_DISABLE_TELEMETRY';

/// Turns Microsoft's telemetry off before ONNX Runtime or ORT-GenAI is
/// opened, unless the app already set [_telemetryVariable] to something (its
/// value is kept).
///
/// ORT-GenAI ships Microsoft's 1DS telemetry on every host since 0.17.0, and
/// ONNX Runtime's official builds since 1.28 do on Linux, macOS, Android and
/// iOS (its `docs/Privacy.md`): on by default, with the OneCollector endpoint
/// compiled in. ONNX Runtime 1.27.0 and ORT-GenAI 0.14.0 had none. For an
/// on-device package it is off here, before either library initializes, and
/// the variable has to be set in the process environment the C runtime sees:
/// `setenv` on POSIX and, on Windows, `_wputenv_s` from the UCRT, since the
/// libraries read it through the CRT and Dart's own environment view is not
/// that copy. `OgaSetTelemetryEnabled(false)` alone is not enough (see the
/// header). Called by both clients, `GenAiFfiClient` and `OrtFfiClient`, before
/// they open their library.
void disableOrtTelemetry() {
  try {
    if (Platform.isWindows) {
      final ucrt = ffi.DynamicLibrary.open('ucrtbase.dll');
      final wgetenv = ucrt.lookupFunction<_WgetenvNative, _WgetenvDart>(
        '_wgetenv',
      );
      final wputenvS = ucrt.lookupFunction<_WputenvSNative, _WputenvSDart>(
        '_wputenv_s',
      );
      final name = _telemetryVariable.toNativeUtf16();
      final value = '1'.toNativeUtf16();
      try {
        if (wgetenv(name) == ffi.nullptr) wputenvS(name, value);
      } finally {
        pkg_ffi.calloc.free(name);
        pkg_ffi.calloc.free(value);
      }
      return;
    }
    final proc = ffi.DynamicLibrary.process();
    final getenv = proc.lookupFunction<_GetenvNative, _GetenvDart>('getenv');
    final setenv = proc.lookupFunction<_SetenvNative, _SetenvDart>('setenv');
    final name = _telemetryVariable.toNativeUtf8();
    final value = '1'.toNativeUtf8();
    try {
      if (getenv(name) == ffi.nullptr) setenv(name, value, 0);
    } finally {
      pkg_ffi.calloc.free(name);
      pkg_ffi.calloc.free(value);
    }
  } catch (e) {
    // Printed, not logged: a release build is where a telemetry that stayed
    // on gets reported, and edgeAiLog is silent there.
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_onnx] Could not set $_telemetryVariable ($e); '
      'telemetry may stay on. Set the variable yourself before the first '
      'model loads.',
    );
  }
}
