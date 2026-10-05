import Flutter

@available(iOS 13.0, *)
public class FlutterGemmaMediaPipePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let platformService = PlatformServiceImpl()
    PlatformServiceSetup.setUp(binaryMessenger: registrar.messenger(), api: platformService)

    let eventChannel = FlutterEventChannel(
      name: "flutter_gemma_stream", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(platformService)
  }
}
