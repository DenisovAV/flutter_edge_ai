// swift-tools-version: 5.9
// The flutter_edge_ai core plugin (macOS). Swift Package Manager manifest; the
// companion `macos/flutter_edge_ai.podspec` is kept for CocoaPods consumers
// (dual-support during the SPM transition).
import PackageDescription

let package = Package(
  name: "flutter_edge_ai",
  platforms: [
    // 10.15: the Flutter-generated FlutterGeneratedPluginSwiftPackage declares
    // 10.15; a lower target (10.14) warns/errors against it.
    .macOS("10.15"),
  ],
  products: [
    .library(name: "flutter-edge-ai", type: .static, targets: ["flutter_edge_ai"]),
  ],
  dependencies: [
    // Same FlutterFramework package as iOS — Flutter generates one on both
    // platforms; the validator rejects anything else (not `FlutterMacOS`).
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "flutter_edge_ai",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
    ),
  ]
)
