// Flutter Gemma Windows Plugin C API
//
// This header defines the C API for plugin registration.

#ifndef FLUTTER_PLUGIN_FLUTTER_GEMMA_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_FLUTTER_GEMMA_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void FlutterGemmaPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_FLUTTER_GEMMA_PLUGIN_C_API_H_
