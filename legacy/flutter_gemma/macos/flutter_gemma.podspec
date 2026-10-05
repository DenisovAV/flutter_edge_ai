#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_gemma.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_gemma'
  s.version          = '1.11.3'
  s.summary          = 'Flutter Gemma - Run Gemma AI models locally on desktop'
  s.description      = <<-DESC
Flutter plugin for running Gemma AI models locally on macOS using LiteRT-LM.
                       DESC
  s.homepage         = 'https://github.com/DenisovAV/flutter_gemma'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Sasha Denisov' => 'denisov.shureg@gmail.com' }

  s.source           = { :path => '.' }
  # SPM layout (flutter_gemma/Sources/flutter_gemma/); Package.swift mirrors it.
  s.source_files     = 'flutter_gemma/Sources/flutter_gemma/**/*'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  # Native LiteRT-LM dylibs are bundled via hook/build.dart (Native Assets)
  # which downloads them at build time — no pod resources / prepare scripts.
end
