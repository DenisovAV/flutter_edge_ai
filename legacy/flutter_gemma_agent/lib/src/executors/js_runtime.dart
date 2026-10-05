// Conditional-export seam for the concrete [JsRuntime] factory, so the web
// build resolves the `package:web` iframe runtime and never imports
// `flutter_inappwebview` (whose web arm has no JS bridge). The native arm
// (`js_runtime_io.dart`) is the default; `js_runtime_web.dart` is selected when
// `dart.library.js_interop` is available (web). Mirrors the repo's
// `flutter_gemma_litertlm` engine export.
export 'js_runtime_io.dart' if (dart.library.js_interop) 'js_runtime_web.dart';
