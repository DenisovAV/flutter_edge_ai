import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_edge_ai/src/registry/engine_registry.dart'
    show EngineRegistry;
import 'package:flutter_edge_ai/src/registry/inference_engine_provider.dart'
    show InferenceEngineProvider;
import 'package:meta/meta.dart' show internal;

/// Opt-in capability interface: an `InferenceEngineProvider` whose models can
/// be open side by side, which `FlutterEdgeAi.openModel` requires.
///
/// An engine that implements this allows its `createModel` to run again while
/// models it built earlier are still open, and those models are independent:
/// closing one leaves the others working. Each holds its own weights and
/// context, and the caller decides how many fit in memory.
///
/// Kept separate from `InferenceEngineProvider` for the reason
/// `HuggingFaceResolverSource` is: engines `implements` the provider, so a new
/// member there would break every third-party engine. An engine opts in with
/// `implements InferenceEngineProvider, MultiModelEngine`.
abstract interface class MultiModelEngine {}

/// The error both native shells throw when no registered engine can run
/// [spec].
@internal
StateError noInferenceEngineError(InferenceModelSpec spec) => StateError(
  'No inference engine can handle this model (ModelFileType.${spec.fileType.name}). '
  'Add the engine package to pubspec.yaml and pass it in inferenceEngines: '
  'of FlutterEdgeAi.initialize(...). Registered engines: '
  '${EngineRegistry.instance.registered.map((e) => e.name).join(", ")}.',
);

/// The engine `FlutterEdgeAi.openModel` builds [spec] with. Throws before any
/// native work when no engine can run [spec], or when the one that would
/// cannot keep several models open ([MultiModelEngine]).
@internal
InferenceEngineProvider requireMultiModelEngine(InferenceModelSpec spec) {
  final engine = EngineRegistry.instance.findFor(spec);
  if (engine == null) throw noInferenceEngineError(spec);
  if (engine is! MultiModelEngine) {
    throw UnsupportedError(
      'FlutterEdgeAi.openModel: the ${engine.name} engine does not support '
      'several open models (it does not implement MultiModelEngine). Use '
      'FlutterEdgeAi.getActiveModel() for this model.',
    );
  }
  return engine;
}
