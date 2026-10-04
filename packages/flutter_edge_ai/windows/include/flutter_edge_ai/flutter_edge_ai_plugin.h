// Flutter Edge AI Windows Plugin
//
// Placeholder plugin class. The real implementation is in Dart
// (FlutterEdgeAiDesktop) using dart:ffi against the LiteRT-LM C API.

#ifndef FLUTTER_PLUGIN_FLUTTER_EDGE_AI_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_EDGE_AI_PLUGIN_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void FlutterEdgeAiPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#include <flutter/plugin_registrar_windows.h>

namespace flutter_edge_ai {

// Placeholder plugin class -- actual implementation is in Dart over dart:ffi
class FlutterEdgeAiPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterEdgeAiPlugin();
  virtual ~FlutterEdgeAiPlugin();

  // Disallow copy and assign.
  FlutterEdgeAiPlugin(const FlutterEdgeAiPlugin&) = delete;
  FlutterEdgeAiPlugin& operator=(const FlutterEdgeAiPlugin&) = delete;
};

}  // namespace flutter_edge_ai

#endif  // FLUTTER_PLUGIN_FLUTTER_EDGE_AI_PLUGIN_H_
