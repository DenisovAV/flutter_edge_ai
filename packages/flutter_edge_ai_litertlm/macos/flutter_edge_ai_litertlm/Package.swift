// swift-tools-version: 5.9
//
// The two LiteRT-LM companion libraries for macOS, as Swift Package Manager
// binary targets (#689). libLiteRtLm links libGemmaModelConstraintProvider and
// dlopens LiteRtLmMetalAccelerator by framework path. They are not Native
// Assets code assets on macOS (#247: `flutter test` cannot rewrite their install
// names), so in an app with Swift Package Manager on, Xcode embeds and signs
// them from here. An app with it off gets them from the macos/Podfile block
// (tool/stage_macos_companions.sh) and the empty podspec next to this folder.
//
// The zips are released on the native tag the hook downloads, built from that
// tag's litertlm-macos_arm64.tar.gz by
// native/litert_lm/package_macos_spm_companions.sh. A native bump changes the
// tag and both checksums here in the same change;
// test/macos_spm_companions_test.dart holds them to the hook.
import Foundation
import PackageDescription

let nativeTag = "native-v0.18.0-g"

let companions: [(name: String, checksum: String)] = [
    ("GemmaModelConstraintProvider", "143edc89f3e3f444955890842adff16b749ca403385100e49a67c9a3466b472c"),
    ("LiteRtLmMetalAccelerator", "ca391e63e87c813bdbfdb79a47d228e6240ef31581f6b9c88b392e0c5a7a9052"),
]

// For a maintainer testing a local native build: when Artifacts/ holds every
// companion as <name>.xcframework, all of them come from there. Never some from
// there and some from the release, which would pair libraries of two builds.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let useLocalArtifacts = companions.allSatisfy {
    FileManager.default.fileExists(
        atPath: packageRoot.appendingPathComponent("Artifacts/\($0.name).xcframework").path)
}

func companionTarget(name: String, checksum: String) -> Target {
    if useLocalArtifacts {
        return .binaryTarget(name: name, path: "Artifacts/\(name).xcframework")
    }
    return .binaryTarget(
        name: name,
        url: "https://github.com/DenisovAV/flutter_edge_ai/releases/download/\(nativeTag)/\(name).xcframework.zip",
        checksum: checksum
    )
}

let package = Package(
    name: "flutter_edge_ai_litertlm",
    // The companions are built for macOS 14 (their LC_BUILD_VERSION), and the
    // app links them, so an app below 14 is refused at build time instead of
    // failing to launch.
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "flutter-edge-ai-litertlm", targets: ["flutter_edge_ai_litertlm"])
    ],
    targets: companions.map { companionTarget(name: $0.name, checksum: $0.checksum) } + [
        .target(
            name: "flutter_edge_ai_litertlm",
            dependencies: companions.map { .target(name: $0.name) }
        )
    ]
)
