// Flutter Edge AI Windows Plugin
//
// Placeholder plugin class. The actual implementation is in Dart
// (FlutterEdgeAiDesktop) which calls the LiteRT-LM C API via dart:ffi. Native
// libraries (LiteRtLm.dll + companions, including dxil.dll/dxcompiler.dll for
// WebGPU/DX12 shader compilation) are bundled via hook/build.dart (Native
// Assets) and placed next to the executable at build time.

#include "flutter_edge_ai/flutter_edge_ai_plugin.h"

namespace flutter_edge_ai {

// static
void FlutterEdgeAiPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  // No-op: desktop implementation is pure Dart over dart:ffi. This class
  // exists only for CMake / Flutter plugin registration compatibility.
}

FlutterEdgeAiPlugin::FlutterEdgeAiPlugin() {}

FlutterEdgeAiPlugin::~FlutterEdgeAiPlugin() {}

}  // namespace flutter_edge_ai

void FlutterEdgeAiPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_edge_ai::FlutterEdgeAiPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
