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
}
