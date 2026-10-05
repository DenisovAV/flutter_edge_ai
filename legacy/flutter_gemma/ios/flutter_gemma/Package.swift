// swift-tools-version: 5.9
// The flutter_gemma core plugin (iOS). Swift Package Manager manifest; the
// companion `ios/flutter_gemma.podspec` is kept for CocoaPods consumers
// (dual-support during the SPM transition).
import PackageDescription

let package = Package(
  name: "flutter_gemma",
  platforms: [
    .iOS("15.0"),
  ],
  products: [
    // type: .static — Flutter's generated plugin package is static; without it
    // SPM links a .dylib (embedding/codesign + App Store validation pain).
    .library(name: "flutter-gemma", type: .static, targets: ["flutter_gemma"]),
  ],
  dependencies: [
    // Flutter generates ONE FlutterFramework SPM package on both iOS and macOS;
    // the tooling validator rejects a Package.swift that doesn't reference
    // "FlutterFramework" (not `Flutter` / `FlutterMacOS`).
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
