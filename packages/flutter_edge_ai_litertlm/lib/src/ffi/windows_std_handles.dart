// The Flutter Windows runner calls AttachConsole(ATTACH_PARENT_PROCESS) as it
// starts. When the parent redirected the app's output without
// STARTF_USESTDHANDLES (cmd.exe's `app.exe > out.log 2> err.log`), that
// replaces the process's standard handles with the parent's console, while
// the C runtimes initialised before it keep the files they were given at
// start: fd 1 and 2 of the shared UCRT (the runner's and the plugins'; the
// reference this file reads) and the Flutter engine's static one, which
// loads with the runner and carries Dart's `print`. LiteRt.dll,
// LiteRtLm.dll, StreamProxy.dll, the WebGPU accelerator and the samplers each
// link the C runtime statically, and a static C runtime copies the standard
// handles once, when its DLL loads: LiteRT-LM's whole log (absl, LiteRT's
// logger, TFLite's) went to the parent's console, not to err.log (Panther
// Lake, native-v0.18.0-f, 2026-10-21). Repointing the standard handles before
// the first of them loads sends it where the app's own output goes.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

const stdOutputHandle = 0xFFFFFFF5; // (DWORD)-11
const stdErrorHandle = 0xFFFFFFF4; // (DWORD)-12

/// The Win32 and UCRT calls [alignStdHandles] makes, injectable for tests.
typedef StdHandleCalls = ({
  /// `_get_osfhandle(fd)` of the shared UCRT; -1 when the fd is closed.
  int Function(int fd) crtHandle,
  int Function(int which) getStdHandle,

  /// `GetConsoleMode` succeeds: a console, not NUL or a COM port, which
  /// `GetFileType` reports as the same FILE_TYPE_CHAR.
  bool Function(int handle) isConsole,

  /// A process-local duplicate, 0 when DuplicateHandle fails.
  int Function(int handle) duplicate,
  bool Function(int which, int handle) setStdHandle,
  void Function(int handle) closeHandle,
});

bool _valid(int h) => h != 0 && h != -1 && h != -2;

/// Repoints STD_OUTPUT_HANDLE and STD_ERROR_HANDLE at a duplicate of the
/// UCRT's fd 1 and 2 when the standard handle is a console and the fd is not:
/// the replacement AttachConsole makes. Any other combination (no console, no
/// redirect, a handle the app set itself) is left alone. Returns the standard
/// handle ids it changed.
///
/// A duplicate, so a later close of the fd (an app that rotates its log with
/// `freopen`) leaves the standard handle and the libraries that copied it on
/// a handle of their own, not on a number Windows may hand out again.
List<int> alignStdHandles(StdHandleCalls calls) {
  final changed = <int>[];
  for (final (fd, which) in const [(1, stdOutputHandle), (2, stdErrorHandle)]) {
    final crt = calls.crtHandle(fd);
    if (!_valid(crt) || calls.isConsole(crt)) continue;
    final std = calls.getStdHandle(which);
    if (!_valid(std) || !calls.isConsole(std)) continue;
    final dup = calls.duplicate(crt);
    if (dup == 0) continue;
    if (calls.setStdHandle(which, dup)) {
      changed.add(which);
    } else {
      calls.closeHandle(dup);
    }
  }
  return changed;
}

bool _alignedInThisIsolate = false;

/// Opens one of the bundled DLLs on Windows, after [alignStdHandles] has run
/// once in this isolate. Every first open of a bundled library goes through
/// here (a later plain open of one already loaded changes nothing): a library
/// that loads first keeps the handles it copied. The alignment only moves
/// where the native log goes, so a failure in it is printed and the library
/// opens anyway.
DynamicLibrary openBundledWindowsLibrary(String name) {
  if (!_alignedInThisIsolate) {
    _alignedInThisIsolate = true;
    try {
      final calls = win32StdHandleCalls();
      if (calls != null) {
        for (final which in alignStdHandles(calls)) {
          edgeAiLog(
            '[flutter_edge_ai_litertlm] Windows: '
            '${which == stdErrorHandle ? 'STD_ERROR_HANDLE' : 'STD_OUTPUT_HANDLE'} '
            "was the parent's console while the app's "
            "${which == stdErrorHandle ? 'stderr' : 'stdout'} is redirected; "
            'pointed it at the redirect so the native log follows it.',
          );
        }
      }
    } on Object catch (e) {
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_litertlm] Windows: could not align the standard '
        "handles with the app's redirected output ($e); the native log may go "
        "to the parent's console.",
      );
    }
  }
  return DynamicLibrary.open(name);
}

typedef _InvalidParameterHandler =
    Void Function(
      Pointer<Uint16>,
      Pointer<Uint16>,
      Pointer<Uint16>,
      Uint32,
      UintPtr,
    );

void _ignoreInvalidParameter(
  Pointer<Uint16> expression,
  Pointer<Uint16> function,
  Pointer<Uint16> file,
  int line,
  int reserved,
) {}

/// The real calls. Null when the process has no ucrtbase.dll loaded: then
/// nothing in it writes through the shared UCRT, and loading it now would
/// build its fd table from the handles AttachConsole already replaced.
@visibleForTesting
StdHandleCalls? win32StdHandleCalls() {
  if (!Platform.isWindows) return null;
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getModuleHandle = kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetModuleHandleW');
  final name = 'ucrtbase.dll'.toNativeUtf16();
  final loaded = getModuleHandle(name) != 0;
  calloc.free(name);
  if (!loaded) return null;
  final ucrt = DynamicLibrary.open('ucrtbase.dll');

  final getOsfHandle = ucrt
      .lookupFunction<IntPtr Function(Int32), int Function(int)>(
        '_get_osfhandle',
      );
  final setInvalidParameterHandler = ucrt
      .lookupFunction<
        Pointer<NativeFunction<_InvalidParameterHandler>> Function(
          Pointer<NativeFunction<_InvalidParameterHandler>>,
        ),
        Pointer<NativeFunction<_InvalidParameterHandler>> Function(
          Pointer<NativeFunction<_InvalidParameterHandler>>,
        )
      >('_set_thread_local_invalid_parameter_handler');
  final getStdHandle = kernel32
      .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'GetStdHandle',
      );
  final setStdHandle = kernel32
      .lookupFunction<Int32 Function(Uint32, IntPtr), int Function(int, int)>(
        'SetStdHandle',
      );
  final getConsoleMode = kernel32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetConsoleMode');
  final getCurrentProcess = kernel32
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final duplicateHandle = kernel32
      .lookupFunction<
        Int32 Function(
          IntPtr,
          IntPtr,
          IntPtr,
          Pointer<IntPtr>,
          Uint32,
          Int32,
          Uint32,
        ),
        int Function(int, int, int, Pointer<IntPtr>, int, int, int)
      >('DuplicateHandle');
  final closeHandle = kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  const duplicateSameAccess = 0x2;

  return (
    crtHandle: (fd) {
      // UCRT opens fd 0-2 at start (-2 for a handle the process lacks), so
      // only an fd the app closed itself reaches the invalid-parameter
      // handler, which ends the process by default: a no-op one on this
      // thread for this one call.
      final ignore = NativeCallable<_InvalidParameterHandler>.isolateLocal(
        _ignoreInvalidParameter,
      );
      final previous = setInvalidParameterHandler(ignore.nativeFunction);
      try {
        return getOsfHandle(fd);
      } finally {
        setInvalidParameterHandler(previous);
        ignore.close();
      }
    },
    getStdHandle: getStdHandle,
    isConsole: (h) {
      final mode = calloc<Uint32>();
      try {
        return getConsoleMode(h, mode) != 0;
      } finally {
        calloc.free(mode);
      }
    },
    // Inheritable, as the handle it replaces was: a child started with
    // inherited handles and no STARTF_USESTDHANDLES gets the standard
    // handles' values, which are only valid in it if they were inherited.
    duplicate: (h) {
      final out = calloc<IntPtr>();
      try {
        final self = getCurrentProcess();
        return duplicateHandle(self, h, self, out, 0, 1, duplicateSameAccess) !=
                0
            ? out.value
            : 0;
      } finally {
        calloc.free(out);
      }
    },
    setStdHandle: (which, h) => setStdHandle(which, h) != 0,
    closeHandle: (h) => closeHandle(h),
  );
}
