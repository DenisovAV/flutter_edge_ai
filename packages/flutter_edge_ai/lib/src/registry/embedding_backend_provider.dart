import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart'
    show EmbeddingPassDescriptor;
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show EmbeddingModelSpec;
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;

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

  /// Explicit accelerator requests this provider honours for [spec].
  ///
  /// Pure and synchronous; no loading or platform I/O. Core calls this once
  /// per request and owns cache identity. An unsupported non-NPU request uses
  /// the legacy CPU key and receives a not-applied notice. NPU always has its
  /// own key. Automatic requests reuse the current embedder for the same model.
  ///
  /// The default preserves existing CPU/NPU request handling. Override for
  /// model-dependent capabilities, for example {cpu, gpu} for native GGUF.
  /// A provider advertising GPU must report the actual loaded accelerator in
  /// EmbeddingPassInfo.activeBackend; a descriptor alone is insufficient.
  Set<PreferredBackend> honouredBackends(EmbeddingModelSpec spec) => const {
    PreferredBackend.cpu,
    PreferredBackend.npu,
  };

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
