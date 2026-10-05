import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart' show InferenceModel;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;

/// A pluggable inference engine (MediaPipe `.task`, LiteRT-LM `.litertlm`, or a
/// third-party `.onnx`/`.gguf` engine).
///
/// Implemented in an engine package (e.g. flutter_gemma_mediapipe) and passed
/// to `FlutterGemma.initialize` via `inferenceEngines:`. Core selects an engine
/// by probing: the first registered engine (highest [priority]) whose
/// [canHandle] returns true for the active model spec wins. There is NO central
/// file-type map — a third-party engine self-selects with zero core changes.
abstract class InferenceEngineProvider {
  /// Human-readable name for diagnostics / error messages (e.g. 'MediaPipe').
  String get name;

  /// Selection precedence on overlap. Core engines use 0; a third party raises
  /// this to take precedence for a spec both could handle.
  int get priority => 0;

  /// Whether this engine can run [spec]. Probed by the registry.
  bool canHandle(InferenceModelSpec spec);

  /// Build a runtime [InferenceModel] for [spec] + [config].
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  );
}
