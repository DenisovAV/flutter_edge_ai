#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_gemma_mediapipe.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_gemma_mediapipe'
  s.version          = '1.0.8'
  s.summary          = 'MediaPipe GenAI (.task) inference backend for flutter_gemma on iOS.'
  s.description      = <<-DESC
MediaPipe GenAI (`.task`) inference backend for the flutter_gemma plugin.
Provides on-device LLM inference (Gemma 4, Gemma3n, Gemma 3, Qwen, Phi-4,
and more) with multimodal vision + audio, function calling, and streaming
on iOS via MediaPipe GenAI.
                       DESC
  s.homepage         = 'https://github.com/DenisovAV/flutter_gemma'
  s.license          = { :file => '../../flutter_gemma/LICENSE' }
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
