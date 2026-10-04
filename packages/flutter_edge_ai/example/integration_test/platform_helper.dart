/// Web-safe platform probe for the L2 webview test. `dart:io`'s `Platform` does
/// not compile under `flutter drive` on web, so the Linux check is reached via a
/// conditional export (the repo's `platform_io_helper` pattern): the `io` arm
/// reads `Platform.isLinux`; the web arm returns false.
library;

export 'platform_helper_io.dart'
    if (dart.library.js_interop) 'platform_helper_web.dart';
