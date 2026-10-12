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
/// Throws [UnsupportedError] on an Android ABI LiteRT-LM ships nothing for, and
/// whatever `DynamicLibrary.open` throws when the library is not in the app.
DynamicLibrary openLiteRtLmLibrary() {
  if (Platform.isIOS) {
    return DynamicLibrary.open(
      '@executable_path/Frameworks/LiteRtLm.framework/LiteRtLm',
    );
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('LiteRtLm.framework/LiteRtLm');
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
    return openLiteRtLmPreferringDefaultScope('libLiteRtLm.so');
  }
  if (Platform.isLinux) {
    // RUNPATH $ORIGIN: its NEEDED libLiteRt.so and
    // libGemmaModelConstraintProvider.so resolve from the bundle's lib/.
    return DynamicLibrary.open('libLiteRtLm.so');
  }
  if (Platform.isWindows) return DynamicLibrary.open('LiteRtLm.dll');
  throw UnsupportedError(
    'LiteRT-LM is not available on ${Platform.operatingSystem}',
  );
}
