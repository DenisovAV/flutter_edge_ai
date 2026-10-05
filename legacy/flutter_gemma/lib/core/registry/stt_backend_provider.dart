import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show SpeechRecognizer;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show SttModelSpec;

/// A pluggable STT backend (LiteRT C API, or a third-party backend). Same
/// probe-chain shape as [EmbeddingBackendProvider]/[InferenceEngineProvider]:
/// selected by probing the STT model spec, highest-priority first match.
///
/// Passed to `FlutterGemma.initialize` via `sttBackends:`.
abstract class SttBackendProvider {
  /// Human-readable name for diagnostics / error messages.
  String get name;

  /// Selection precedence on overlap. Core backends use 0.
  int get priority => 0;

  /// Whether this backend can serve [spec]. Probed by the registry.
  bool canHandle(SttModelSpec spec);

  /// Build a runtime [SpeechRecognizer] for [spec] + [config].
  Future<SpeechRecognizer> createModel(SttModelSpec spec, RuntimeConfig config);
}
