#
# Present so an app with Swift Package Manager off still builds: Flutter refuses
# a plugin that ships only a Package.swift there. It delivers nothing, as the
# Swift package does not since litertlm_dart 0.20.0 (no macOS companions).
#
Pod::Spec.new do |s|
  s.name             = 'flutter_edge_ai_litertlm'
  s.version          = '1.21.3'
  s.summary          = 'macOS plugin shell of flutter_edge_ai_litertlm; delivers no library.'
  s.homepage         = 'https://flutteredge.ai'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Sasha Denisov' => 'denisov.shureg@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_edge_ai_litertlm/Sources/flutter_edge_ai_litertlm/**/*.swift'
  s.dependency 'FlutterMacOS'
  # The macOS minimum the plugin has declared since #689; see Package.swift.
  s.platform         = :osx, '14.0'
  s.swift_version    = '5.0'
end
