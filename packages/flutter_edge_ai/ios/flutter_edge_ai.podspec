#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_edge_ai.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_edge_ai'
  s.version          = '2.1.2'
  s.summary          = 'Flutter Edge AI core — on-device AI for Flutter on iOS.'
  s.description      = <<-DESC
Core of Flutter Edge AI: model installation and the engine registries.
Inference engines are opt-in packages — `flutter_edge_ai_litertlm`
(`.litertlm`), `flutter_edge_ai_mediapipe` (`.task`), `flutter_edge_ai_onnx`
and `flutter_edge_ai_builtin_ai` (Apple Foundation Models); embeddings,
RAG and speech come in their own packages too.
                       DESC
  s.homepage         = 'https://github.com/DenisovAV/flutter_edge_ai'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Flutter Berlin' => 'flutter@flutterberlin.dev' }
  s.source           = { :path => '.' }
  # Sources live under the SPM layout (flutter_edge_ai/Sources/flutter_edge_ai/);
  # the companion Package.swift gives SPM consumers the same sources.
  s.source_files = 'flutter_edge_ai/Sources/flutter_edge_ai/**/*.swift'
  s.dependency 'Flutter'
  # iOS 15.0 (#441). The 16.0 this replaces was MediaPipe GenAI's, and MediaPipe
  # has lived in flutter_edge_ai_mediapipe since the 1.0 split — that package still
  # declares 16.0 in its own podspec.
  # Nothing in this package requires 15: its Swift is plain Foundation. Measured at
  # #441 — the highest floor in the transitive native graph was background_downloader's
  # 14.0, and Flutter 3.44's own template floor was 13.0. 15.0 is a deliberate choice:
  # it matches flutter_edge_ai_builtin_ai, where 15 IS the lowest free floor (Swift
  # Concurrency), and the iOS 26 SDK's RecommendedDeploymentTarget. Not a requirement.
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
  s.swift_version = '5.0'

  # No script_phase needed: the upstream LiteRT-LM dlopen path is patched in
  # native/litert_lm/patch_c_api.sh (FLUTTER_GEMMA_GPU_REGISTRY_PATCH) to load
  # accelerator frameworks via their @executable_path-relative .framework path,
  # so the host app's Frameworks/ stays App-Store-clean (no rogue dylibs that
  # would trigger ITMS-90432, see #245).
end
