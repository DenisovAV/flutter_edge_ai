package dev.flutterberlin.flutter_gemma_mediapipe

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel

/** FlutterGemmaMediaPipePlugin — hosts the MediaPipe (.task) PlatformService
 *  HostApi + the "flutter_gemma_stream" async-result EventChannel. */
class FlutterGemmaMediaPipePlugin : FlutterPlugin {
  private var service: PlatformServiceImpl? = null
  private lateinit var eventChannel: EventChannel

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    val svc = PlatformServiceImpl(binding.applicationContext)
    service = svc
    eventChannel = EventChannel(binding.binaryMessenger, "flutter_gemma_stream")
    eventChannel.setStreamHandler(svc)
    PlatformService.setUp(binding.binaryMessenger, svc)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    PlatformService.setUp(binding.binaryMessenger, null)
    eventChannel.setStreamHandler(null)
    service?.cleanup()
    service = null
  }
}
