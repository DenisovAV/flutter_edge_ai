import Flutter

public class FlutterGemmaPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
      // Bundled resources method channel
      let bundledChannel = FlutterMethodChannel(
        name: "flutter_gemma_bundled",
        binaryMessenger: registrar.messenger())
      bundledChannel.setMethodCallHandler { (call, result) in
        if call.method == "getBundledResourcePath" {
          guard let args = call.arguments as? [String: Any],
                let resourceName = args["resourceName"] as? String else {
            result(FlutterError(code: "INVALID_ARGS",
                               message: "resourceName is required",
                               details: nil))
            return
          }

          // Split resourceName into name and extension
          let components = resourceName.split(separator: ".")
          let name = String(components[0])
          let ext = components.count > 1 ? String(components[1]) : ""

          // Get path from Bundle.main
          if let path = Bundle.main.path(forResource: name, ofType: ext) {
            result(path)
          } else {
            result(FlutterError(code: "NOT_FOUND",
                               message: "Resource not found in bundle: \(resourceName)",
                               details: nil))
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
  }
}
