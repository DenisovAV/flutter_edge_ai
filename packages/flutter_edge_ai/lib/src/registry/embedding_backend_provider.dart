import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart'
    show EmbeddingPassDescriptor;
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show EmbeddingModelSpec;
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';

/// A pluggable embedding backend (LiteRT C API + Gecko/EmbeddingGemma, ONNX,
/// or a third-party backend). Same probe-chain shape as
/// `InferenceEngineProvider`: selected by probing the embedding model spec,
/// highest-priority first match.
///
/// Passed to `FlutterEdgeAi.initialize` via `embeddingBackends:`. A backend
/// only DESCRIBES what to run ([describe]); core builds, hosts, validates and
/// closes the model, so every engine gets the same request checks and the
/// same close semantics.
///
/// Extend it (`final class MyBackend extends EmbeddingBackendProvider`);
/// `base`, so it cannot be implemented and a member added later reaches every
/// backend through its superclass.
abstract base class EmbeddingBackendProvider {
  const EmbeddingBackendProvider();

  /// Human-readable name for diagnostics / error messages.
  String get name;

  /// Selection precedence on overlap. Core backends use 0.
  int get priority => 0;

  /// Whether this backend can serve [spec]. Probed by the registry.
  bool canHandle(EmbeddingModelSpec spec);

  /// A pure description of what to run for [spec] with [config].
  ///
  /// Runs on the caller's isolate. Must not open native libraries, spawn
  /// isolates or download; it may resolve platform paths (path_provider), as
  /// the LLM engine does for its cache directory. Throws
  /// `EmbeddingLoadException` for a request this backend refuses — e.g. a
  /// modality in `config.supportImage` / `supportAudio` it cannot embed —
  /// which surfaces before any isolate exists.
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  );
}
