import 'package:flutter_edge_ai/engine.dart';

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
