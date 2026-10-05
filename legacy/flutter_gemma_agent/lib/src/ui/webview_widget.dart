// Conditional-export seam for the inline [WebviewResult] renderer, so the web
// build resolves the `package:web` `<iframe>` widget and never imports
// `flutter_inappwebview` (whose web arm has no JS bridge). The native arm
// (`webview_widget_io.dart`) is the default; `webview_widget_web.dart` is
// selected when `dart.library.js_interop` is available (web). Mirrors the
// `js_runtime.dart` runtime export.
export 'webview_widget_io.dart'
    if (dart.library.js_interop) 'webview_widget_web.dart';
