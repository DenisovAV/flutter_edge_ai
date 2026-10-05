// Flutter Gemma Linux Plugin
//
// Placeholder plugin class. The actual implementation is in Dart
// (FlutterGemmaDesktop) which calls the LiteRT-LM C API via dart:ffi. Native
// libraries (libLiteRtLm.so + companions) are bundled via hook/build.dart
// (Native Assets) and placed next to the executable at build time.

#include "include/flutter_gemma/flutter_gemma_plugin.h"

#include <flutter_linux/flutter_linux.h>

extern "C" __attribute__((visibility("default")))
void flutter_gemma_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  // No-op: desktop implementation is pure Dart over dart:ffi. This function
  // exists only for the Flutter plugin registration ABI.
}
