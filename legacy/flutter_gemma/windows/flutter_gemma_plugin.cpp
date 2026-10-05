// Flutter Gemma Windows Plugin
//
// Placeholder plugin class. The actual implementation is in Dart
// (FlutterGemmaDesktop) which calls the LiteRT-LM C API via dart:ffi. Native
// libraries (LiteRtLm.dll + companions, including dxil.dll/dxcompiler.dll for
// WebGPU/DX12 shader compilation) are bundled via hook/build.dart (Native
// Assets) and placed next to the executable at build time.

#include "flutter_gemma/flutter_gemma_plugin.h"

namespace flutter_gemma {

// static
void FlutterGemmaPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  // No-op: desktop implementation is pure Dart over dart:ffi. This class
  // exists only for CMake / Flutter plugin registration compatibility.
}

FlutterGemmaPlugin::FlutterGemmaPlugin() {}

FlutterGemmaPlugin::~FlutterGemmaPlugin() {}

}  // namespace flutter_gemma

void FlutterGemmaPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_gemma::FlutterGemmaPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
