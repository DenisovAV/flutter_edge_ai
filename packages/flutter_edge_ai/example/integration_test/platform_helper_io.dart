import 'dart:io' as io;

/// True on Linux, where the JS executor has no webview implementation. Used by
/// the L2 test to skip the real-webview scenarios (S1–S5) and assert S6's
/// ErrorResult instead.
bool get isLinux => io.Platform.isLinux;

/// True on Windows. `HeadlessInAppWebView` (WebView2) access-violation-crashes
/// under the `flutter test` integration harness: WebView2 (Chromium) needs a
/// real window/HWND that the headless test runner doesn't provide, unlike macOS
/// WKWebView which renders offscreen natively. Proven by elimination — four
/// Dart-level fixes (shouldOverrideUrlLoading, evaluateJavascript,
/// WebViewEnvironment.userDataFolder, our io arm) didn't change the crash, and a
/// minimal no-our-code headless test crashes identically, while the SAME code as
/// a `flutter run` app (with a real window) works. The loopback secure-context
/// is probe-proven on Windows WebView2 — only the test harness is incompatible —
/// so the L2 real-webview scenarios are skipped here, not failed.
bool get isWindows => io.Platform.isWindows;

/// True on the iOS Simulator, which has no GPU backend for LiteRT-LM (Metal on
/// the simulator caps a single allocation at 256 MB), so a GPU run there always
/// falls back to CPU. CoreSimulator sets this variable in simulator processes
/// only.
bool get isIosSimulator =>
    io.Platform.isIOS &&
    io.Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');
