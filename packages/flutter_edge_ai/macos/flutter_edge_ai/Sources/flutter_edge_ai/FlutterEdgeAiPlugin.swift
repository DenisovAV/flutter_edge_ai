import FlutterMacOS

// Placeholder class for CocoaPods compatibility.
// Actual implementation is in Dart (FlutterEdgeAiDesktop) which uses dart:ffi
// to call the LiteRT-LM C API directly. Native libs are bundled via
// hook/build.dart (Native Assets).
public class FlutterEdgeAiPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // No-op: desktop implementation is pure Dart over dart:ffi.
  }
}
