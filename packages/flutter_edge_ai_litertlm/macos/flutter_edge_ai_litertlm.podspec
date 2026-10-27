#
# Present so an app with Swift Package Manager off still builds: Flutter refuses
# a plugin that ships only a Package.swift there. It delivers nothing; in that
# mode the companions come from the macos/Podfile block (#689).
#
Pod::Spec.new do |s|
  s.name             = 'flutter_edge_ai_litertlm'
  s.version          = '0.0.1'
  s.summary          = 'macOS packaging of the LiteRT-LM companion libraries.'
  s.homepage         = 'https://flutteredge.ai'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Sasha Denisov' => 'denisov.shureg@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_edge_ai_litertlm/Sources/flutter_edge_ai_litertlm/**/*.swift'
  s.dependency 'FlutterMacOS'
  # The companions are built for macOS 14; see Package.swift.
  s.platform         = :osx, '14.0'
  s.swift_version    = '5.0'
end
