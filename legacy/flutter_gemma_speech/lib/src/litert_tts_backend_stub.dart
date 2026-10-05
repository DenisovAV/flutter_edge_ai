import 'package:flutter_gemma/core/registry/tts_backend_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show SpeechSynthesizer;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show TtsModelSpec;

/// Web stub for [LiteRtTtsBackend] — `flutter_gemma_speech` has no web TTS
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
      'flutter_gemma_speech has no web TTS arm (native-only).',
    );
  }
}
