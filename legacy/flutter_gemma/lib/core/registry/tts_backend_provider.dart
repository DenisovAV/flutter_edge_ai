import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show SpeechSynthesizer;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show TtsModelSpec;

/// A pluggable TTS backend (LiteRT C API, or a third-party backend). Same
/// probe-chain shape as [EmbeddingBackendProvider]/[InferenceEngineProvider]:
/// selected by probing the TTS model spec, highest-priority first match.
///
/// Passed to `FlutterGemma.initialize` via `ttsBackends:`.
abstract class TtsBackendProvider {
  /// Human-readable name for diagnostics / error messages.
  String get name;

  /// Selection precedence on overlap. Core backends use 0.
  int get priority => 0;

  /// Whether this backend can serve [spec]. Probed by the registry.
  bool canHandle(TtsModelSpec spec);

  /// Build a runtime [SpeechSynthesizer] for [spec] + [config].
  Future<SpeechSynthesizer> createModel(
    TtsModelSpec spec,
    RuntimeConfig config,
  );
}
