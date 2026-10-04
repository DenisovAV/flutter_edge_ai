import 'package:flutter_edge_ai/core/registry/tts_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show SpeechSynthesizer;
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show TtsModelSpec;

/// Web stub for [LiteRtTtsBackend] — `flutter_edge_ai_speech` has no web TTS
/// arm (native-only). Registers cleanly so `initialize` doesn't break on
/// web, but building a model throws.
class LiteRtTtsBackend implements TtsBackendProvider {
  const LiteRtTtsBackend();

  @override
  String get name => 'LiteRT TTS';

  @override
  int get priority => 0;

  @override
  bool canHandle(TtsModelSpec spec) => true;

  @override
  Future<SpeechSynthesizer> createModel(
    TtsModelSpec spec,
    RuntimeConfig config,
  ) async {
    throw UnsupportedError(
      'flutter_edge_ai_speech has no web TTS arm (native-only).',
    );
  }
}
