import 'package:flutter_edge_ai/engine.dart';

/// Web stub for [LiteRtSttBackend] — the STT web arm is a follow-on (see the
/// design spec's "Out of scope"). Registers cleanly so `initialize` doesn't
/// break on web, but building a model throws.
class LiteRtSttBackend implements SttBackendProvider {
  const LiteRtSttBackend();

  @override
  String get name => 'LiteRT STT';

  @override
  int get priority => 0;

  @override
  bool canHandle(SttModelSpec spec) => true;

  @override
  Future<SpeechRecognizer> createModel(
    SttModelSpec spec,
    RuntimeConfig config,
  ) async {
    throw UnsupportedError(
      'flutter_edge_ai_speech has no web STT arm yet (follow-on).',
    );
  }
}
