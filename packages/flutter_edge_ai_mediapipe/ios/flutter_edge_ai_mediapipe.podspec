#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_edge_ai_mediapipe.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_edge_ai_mediapipe'
  s.version          = '1.1.1'
  s.summary          = 'MediaPipe GenAI (.task) inference backend for flutter_edge_ai on iOS.'
  s.description      = <<-DESC
MediaPipe GenAI (`.task`) inference backend for the flutter_edge_ai plugin.
Provides on-device LLM inference (Gemma 4, Gemma3n, Gemma 3, Qwen, Phi-4,
and more) with multimodal vision + audio, function calling, and streaming
on iOS via MediaPipe GenAI.
                       DESC
  s.homepage         = 'https://github.com/DenisovAV/flutter_edge_ai'
  s.license          = { :file => '../../flutter_edge_ai/LICENSE' }
  s.author           = { 'Flutter Berlin' => 'flutter@flutterberlin.dev' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'MediaPipeTasksGenAI', '= 0.10.33'
  s.dependency 'MediaPipeTasksGenAIC', '= 0.10.33'
  # 16.0 is MediaPipeTasksGenAI's floor. It is the ONLY package that needs it —
  # core, litertlm, built-in AI and embeddings build from 15.0 since #441.
  s.platform = :ios, '16.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
  s.swift_version = '5.0'
end
