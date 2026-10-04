/// Web arm: there is no Linux on web (and JS skills run there via the iframe
/// runtime), so the Linux gate is always false.
bool get isLinux => false;

/// Web arm: the Windows headless-webview×flutter-test crash doesn't apply on
/// web (the iframe runtime is used there), so the Windows gate is always false.
bool get isWindows => false;

/// Web arm: never the iOS Simulator.
bool get isIosSimulator => false;
