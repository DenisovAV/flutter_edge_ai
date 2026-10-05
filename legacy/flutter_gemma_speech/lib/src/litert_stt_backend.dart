import 'package:flutter_gemma/core/registry/stt_backend_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show SpeechRecognizer;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show SttModelSpec;
import 'litert/litert_speech_recognizer.dart';
import 'model/stt_model_profile.dart';

/// LiteRT C API STT backend. Sole `.tflite` STT backend — the *model* is
/// selected by [SttModelSpec.sttModelType] (mirrors [InferenceModelSpec.modelType]),
/// not by the backend, so `canHandle` is unconditionally `true`.
///
/// Pure factory; core owns the singleton lifecycle via
/// [SpeechRecognizer.addCloseListener]. Mirrors `LiteRtEmbeddingBackend`.
class LiteRtSttBackend implements SttBackendProvider {
  const LiteRtSttBackend();

  @override
  String get name => 'LiteRT STT';

  @override
  int get priority => 0;

  @override
  bool canHandle(SttModelSpec spec) => true; // sole STT backend

  @override
  Future<SpeechRecognizer> createModel(
    SttModelSpec spec,
    RuntimeConfig config,
  ) async {
    final tokenizerPath = config.tokenizerPath;
    if (tokenizerPath == null) {
      throw StateError(
        'LiteRtSttBackend requires config.tokenizerPath (resolved by core '
        'from the active STT model).',
      );
    }
    // `config.language` reaches here from `getActiveStt(language:)`. It is NOT
    // baked into the profile: it becomes the recognizer's mutable default, so
    // the same recognizer can later be retargeted or overridden per call
    // without reloading the model. The profile keeps its own default (`<|en|>`
    // for whisper), which is what a null here means.
    //
    // Not validated here on purpose — `LiteRtSpeechRecognizer`'s `language`
    // setter owns that, and `create` assigns through it. A copy of the check
    // here would be a second place to keep in sync, and would still not cover
    // the shells' retarget path or a direct `recognizer.language = …`.
    //
    // spec.sttModelType (e.g. SttModelType.moonshine) selects the runtime
    // profile — this backend never hardcodes a model.
    return LiteRtSpeechRecognizer.create(
      profile: SttModelProfile.forType(spec.sttModelType),
      modelPath: config.modelPath,
      tokenizerPath: tokenizerPath,
      preferredBackend: config.preferredBackend,
      language: config.language,
      onClose: () {},
    );
  }
}
