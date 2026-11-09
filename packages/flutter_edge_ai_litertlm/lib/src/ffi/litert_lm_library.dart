// Opens libLiteRtLm — the one loader shared by the LLM client's isolate helper
// (`litert_lm_client.dart`) and the EmbeddingGemma 2 pass, which runs in core's
// embedding worker isolate (R5 §4.11).
//
// Package-private. `LiteRtLmFfiClient._ensureBindings` keeps its own open,
// because the LLM path needs more than the handle: the RTLD_GLOBAL preloads on
// Linux and Windows (WebGPU accelerator, samplers) and the strict
// default-scope load on Android. Neither caller here needs those: they resolve
// every symbol through the returned handle. That holds for the embedding pass
// on the NPU too: the Qualcomm dispatch LiteRT loads from the dispatch
// directory has no undefined LiteRt* symbols (NEEDED: libc, libm, libdl,
// liblog on Android; the C/C++ runtime on Linux), so it needs no global scope.

import 'dart:ffi';
import 'dart:io';

import 'litert_default_scope.dart';
import 'litert_lm_runtime_check.dart';
import 'macos_load_error.dart';
import 'windows_std_handles.dart';

/// Opens the LiteRT-LM shared library for the current platform.
///
/// Top-level so it can be called from a spawned isolate, which cannot capture
/// `this` or any other non-const closure state.
///
/// On Android it goes through [openLiteRtLmPreferringDefaultScope] (#447:
/// whichever caller opens the library FIRST decides whether its exports are
/// reachable through `dlsym(RTLD_DEFAULT)`, which the LLM path's stream-ABI
/// probe needs; the embedding pass can be that first caller). Best effort: an
/// embeddings-only app must not fail over a condition it does not depend on.
///
/// Throws [UnsupportedError] on an Android ABI LiteRT-LM ships nothing for,
/// whatever `DynamicLibrary.open` throws when the library is not in the app
/// (on macOS with a message that names the cause, [openMacOSLiteRtLm]), and
/// [StateError] when the library under that name is another package's
/// LiteRT-LM ([checkOwnLiteRtLmBuild]).
DynamicLibrary openLiteRtLmLibrary() {
  if (Platform.isIOS) {
    const path = '@executable_path/Frameworks/LiteRtLm.framework/LiteRtLm';
    return requireOwnLiteRtLmBuild(DynamicLibrary.open(path), path);
  }
  if (Platform.isMacOS) {
    return requireOwnLiteRtLmBuild(openMacOSLiteRtLm(), macOSLiteRtLmFramework);
  }
  if (Platform.isAndroid) {
    // LiteRT-LM ships android_arm64 only. Without this guard an x86_64
    // emulator's failure would name libStreamProxy, the first library the
    // scope helper opens, instead of the ABI (mirrors litert_lm_client.dart).
    if (Abi.current() != Abi.androidArm64) {
      throw UnsupportedError(
        'LiteRT-LM requires an arm64-v8a Android device (got '
        '${Abi.current()}); it ships no other Android ABI.',
      );
    }
    const path = 'libLiteRtLm.so';
    return requireOwnLiteRtLmBuild(
      openLiteRtLmPreferringDefaultScope(path),
      path,
    );
  }
  if (Platform.isLinux) {
    // RUNPATH $ORIGIN: its NEEDED libLiteRt.so and
    // libGemmaModelConstraintProvider.so resolve from the bundle's lib/.
    const path = 'libLiteRtLm.so';
    return requireOwnLiteRtLmBuild(DynamicLibrary.open(path), path);
  }
  if (Platform.isWindows) {
    // Through the std-handle realignment: the embedding pass can be the first
    // to load this static-CRT DLL (windows_std_handles.dart).
    const path = 'LiteRtLm.dll';
    return requireOwnLiteRtLmBuild(openBundledWindowsLibrary(path), path);
  }
  throw UnsupportedError(
    'LiteRT-LM is not available on ${Platform.operatingSystem}',
  );
}
