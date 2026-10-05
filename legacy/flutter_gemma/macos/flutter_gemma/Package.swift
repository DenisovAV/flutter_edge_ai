// swift-tools-version: 5.9
// The flutter_gemma core plugin (macOS). Swift Package Manager manifest; the
// companion `macos/flutter_gemma.podspec` is kept for CocoaPods consumers
// (dual-support during the SPM transition).
import PackageDescription

let package = Package(
  name: "flutter_gemma",
  platforms: [
    // 10.15: the Flutter-generated FlutterGeneratedPluginSwiftPackage declares
    // 10.15; a lower target (10.14) warns/errors against it.
    .macOS("10.15"),
  ],
  products: [
    .library(name: "flutter-gemma", type: .static, targets: ["flutter_gemma"]),
  ],
  dependencies: [
    // Same FlutterFramework package as iOS — Flutter generates one on both
    // platforms; the validator rejects anything else (not `FlutterMacOS`).
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "flutter_gemma",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
    ),
  ]
)
