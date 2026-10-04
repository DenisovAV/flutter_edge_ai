#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_edge_ai.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_edge_ai'
  s.version          = '2.0.0'
  s.summary          = 'Flutter Edge AI - Run Gemma AI models locally on desktop'
  s.description      = <<-DESC
Flutter plugin for running Gemma AI models locally on macOS using LiteRT-LM.
                       DESC
  s.homepage         = 'https://github.com/DenisovAV/flutter_edge_ai'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Sasha Denisov' => 'denisov.shureg@gmail.com' }

  s.source           = { :path => '.' }
  # SPM layout (flutter_edge_ai/Sources/flutter_edge_ai/); Package.swift mirrors it.
  s.source_files     = 'flutter_edge_ai/Sources/flutter_edge_ai/**/*'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # Native LiteRT-LM dylibs are bundled via hook/build.dart (Native Assets)
  # which downloads them at build time — no pod resources / prepare scripts.
end
