import 'package:flutter_gemma/core/registry/tts_backend_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show SpeechSynthesizer;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show TtsModelSpec;
import 'litert/litert_speech_synthesizer.dart';
import 'model/tts_model_profile.dart';

/// LiteRT TTS backend. Sole TTS backend — the model is selected by
/// [TtsModelSpec.ttsModelType], so `canHandle` is unconditionally true. Pure
/// factory; core owns the singleton lifecycle via [SpeechSynthesizer.addCloseListener].
class LiteRtTtsBackend implements TtsBackendProvider {
  const LiteRtTtsBackend();

  @override
  String get name => 'LiteRT TTS';

  @override
  int get priority => 0;

  @override
  bool canHandle(TtsModelSpec spec) => true; // sole TTS backend

  @override
  Future<SpeechSynthesizer> createModel(
    TtsModelSpec spec,
    RuntimeConfig config,
  ) async {
    final artifactPaths = config.artifactPaths;
    if (artifactPaths == null || artifactPaths.isEmpty) {
      throw StateError(
        'LiteRtTtsBackend requires config.artifactPaths (resolved by core from '
        'the active TTS model bundle).',
      );
    }
    // spec.ttsModelType (e.g. TtsModelType.matcha) selects the runtime
    // profile — this backend never hardcodes a model.
    //
    // config.language is Qwen3-only — threaded from
    // `FlutterGemma.getActiveTts(language: ...)` through `RuntimeConfig`;
    // null falls back to `LiteRtSpeechSynthesizer.create`'s own `'english'`
    // default. Matcha ignores it (no language parameter). No `voice` here:
    // v1 never surfaces a voice picker anywhere in the public API, so this
    // backend always takes `LiteRtSpeechSynthesizer.create`'s default
    // (the bundle's single demo voice) — see that method's `voice` doc.
    return LiteRtSpeechSynthesizer.create(
      profile: TtsModelProfile.forType(spec.ttsModelType),
      artifactPaths: artifactPaths,
      preferredBackend: config.preferredBackend,
      language: config.language ?? 'english',
      onClose: () {},
    );
  }
}
