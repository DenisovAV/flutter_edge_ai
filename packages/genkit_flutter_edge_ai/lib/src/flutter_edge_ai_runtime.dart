import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;

/// Abstraction over flutter_edge_ai static API for testability.
///
/// Instead of calling [gemma.FlutterEdgeAi.getActiveModel] directly,
/// production code uses [DefaultFlutterEdgeAiRuntime] while tests
/// can substitute a fake implementation.
abstract class FlutterEdgeAiRuntime {
  /// Retrieves the active inference model with the given configuration.
  Future<gemma.InferenceModel> getActiveModel({
    int maxTokens = 1024,
    bool supportImage = false,
    bool supportAudio = false,
    bool? enableSpeculativeDecoding,
    gemma.PreferredBackend? preferredBackend,
    gemma.PreferredBackend? preferredVisionBackend,
    gemma.PreferredBackend? preferredAudioBackend,
  });

  /// Retrieves the active embedding model.
  Future<gemma.EmbeddingModel> getActiveEmbedder({
    gemma.PreferredBackend? preferredBackend,
  });

  /// The name of the active inference model, or null when none is set. A
  /// model handle loaded under another name belongs to a model that is no
  /// longer active.
  String? get activeModelName;

  /// The name of the active embedding model, or null when none is set.
  String? get activeEmbedderName;
}

/// Default runtime that delegates to [gemma.FlutterEdgeAi] static methods.
class DefaultFlutterEdgeAiRuntime implements FlutterEdgeAiRuntime {
  const DefaultFlutterEdgeAiRuntime();

  @override
  Future<gemma.InferenceModel> getActiveModel({
    int maxTokens = 1024,
    bool supportImage = false,
    bool supportAudio = false,
    bool? enableSpeculativeDecoding,
    gemma.PreferredBackend? preferredBackend,
    gemma.PreferredBackend? preferredVisionBackend,
    gemma.PreferredBackend? preferredAudioBackend,
  }) {
    return gemma.FlutterEdgeAi.getActiveModel(
      maxTokens: maxTokens,
      supportImage: supportImage,
      supportAudio: supportAudio,
      enableSpeculativeDecoding: enableSpeculativeDecoding,
      preferredBackend: preferredBackend,
      preferredVisionBackend: preferredVisionBackend,
      preferredAudioBackend: preferredAudioBackend,
    );
  }

  @override
  Future<gemma.EmbeddingModel> getActiveEmbedder({
    gemma.PreferredBackend? preferredBackend,
  }) {
    return gemma.FlutterEdgeAi.getActiveEmbedder(
      preferredBackend: preferredBackend,
    );
  }

  @override
  String? get activeModelName => gemma.FlutterEdgeAi.activeModelSpec?.name;

  @override
  String? get activeEmbedderName =>
      gemma.FlutterEdgeAi.activeEmbedderSpec?.name;
}
