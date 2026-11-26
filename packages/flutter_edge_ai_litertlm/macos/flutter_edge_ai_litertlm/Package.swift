// swift-tools-version: 5.9
//
// The plugin's macOS Swift package. Up to litertlm_dart 0.19.1+4 it brought
// LiteRT-LM's two macOS companion libraries into the app as binary targets
// (#689). From litertlm_dart 0.20.0 (native-v0.20.0) libLiteRtLm links no
// companion: the tool-call constraints are built into it (LLGuidance) and so
// is the Metal accelerator, and a second Metal accelerator in the process is
// what native-v0.20.0's manifest forbids. So the package brings nothing; it
// stays so that an app with Swift Package Manager on keeps resolving the
// plugin, and keeps the macOS minimum the plugin has declared since #689.
import PackageDescription

let package = Package(
    name: "flutter_edge_ai_litertlm",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "flutter-edge-ai-litertlm", targets: ["flutter_edge_ai_litertlm"])
    ],
    targets: [
        .target(name: "flutter_edge_ai_litertlm")
    ]
)
