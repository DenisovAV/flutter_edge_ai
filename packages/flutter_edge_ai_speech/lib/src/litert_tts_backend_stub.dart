import 'package:flutter_edge_ai/engine.dart';

import 'catalog/speech_catalog.dart' show LiteRtSpeechModels;

/// Web stub for [LiteRtTtsBackend] — `flutter_edge_ai_speech` has no web TTS
/// arm (native-only). Registers cleanly so `initialize` doesn't break on
/// web, but building a model throws.
class LiteRtTtsBackend implements TtsBackendProvider, ModelCatalogSource {
  const LiteRtTtsBackend();

  @override
  String get name => 'LiteRT TTS';

  /// The text-to-speech models this backend runs, pinned to Hugging Face commits:
  /// [LiteRtSpeechModels.ttsCatalog]. `FlutterEdgeAi.catalog` includes it once
  /// the backend is passed to `initialize`.
  @override
  ModelCatalog get modelCatalog => LiteRtSpeechModels.ttsCatalog;

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
