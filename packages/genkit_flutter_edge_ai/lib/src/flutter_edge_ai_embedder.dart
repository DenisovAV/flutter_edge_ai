import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

import 'backend_parse.dart';
import 'flutter_edge_ai_options.dart';
import 'flutter_edge_ai_runtime.dart';

/// Creates a Genkit [Embedder] action backed by flutter_edge_ai's embedding model.
///
/// The embedding model is lazily created on first call and cached for reuse.
Embedder<FlutterEdgeAiEmbedConfig> createFlutterEdgeAiEmbedder({
  required String name,
  required FlutterEdgeAiRuntime runtime,
}) {
  gemma.EmbeddingModel? cachedEmbedder;
  gemma.PreferredBackend? cachedBackend;

  return Embedder<FlutterEdgeAiEmbedConfig>(
    name: name,
    fn: (request, _) async {
      // Parse optional backend preference.
      FlutterEdgeAiEmbedConfig? config;
      if (request.options != null) {
        try {
          config = FlutterEdgeAiEmbedConfig.fromJson(request.options!);
        } catch (e) {
          throw GenkitException(
            'Invalid embed options: $e',
            status: StatusCode.invalidArgument,
          );
        }
      }

      // Parse preferredBackend string to enum.
      final backend = parsePreferredBackend(config?.preferredBackend);

      // Get or create embedding model (invalidate on backend change).
      if (cachedEmbedder == null || cachedBackend != backend) {
        cachedEmbedder = await runtime.getActiveEmbedder(
          preferredBackend: backend,
        );
        cachedBackend = backend;
      }

      // Extract text from each document.
      final texts = request.input.map(_documentToText).toList(growable: false);

      // Generate embeddings.
      final vectors = await cachedEmbedder!.generateEmbeddings(texts);

      return EmbedResponse(
        embeddings: vectors
            .asMap()
            .entries
            .map(
              (entry) => Embedding(
                embedding: entry.value,
                metadata: request.input[entry.key].metadata,
              ),
            )
            .toList(growable: false),
      );
    },
  );
}

/// Extracts plain text from a [DocumentData] by joining its text parts.
String _documentToText(DocumentData doc) {
  final buffer = StringBuffer();
  for (final part in doc.content) {
    if (part.isText) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(part.text);
    }
  }
  return buffer.toString();
}
