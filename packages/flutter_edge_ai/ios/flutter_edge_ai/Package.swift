// swift-tools-version: 5.9
// The flutter_edge_ai core plugin (iOS). Swift Package Manager manifest; the
// companion `ios/flutter_edge_ai.podspec` is kept for CocoaPods consumers
// (dual-support during the SPM transition).
import PackageDescription

let package = Package(
  name: "flutter_edge_ai",
  platforms: [
    .iOS("15.0"),
  ],
  products: [
    // type: .static — Flutter's generated plugin package is static; without it
    // SPM links a .dylib (embedding/codesign + App Store validation pain).
    .library(name: "flutter-edge-ai", type: .static, targets: ["flutter_edge_ai"]),
  ],
  dependencies: [
    // Flutter generates ONE FlutterFramework SPM package on both iOS and macOS;
    // the tooling validator rejects a Package.swift that doesn't reference
    // "FlutterFramework" (not `Flutter` / `FlutterMacOS`).
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
