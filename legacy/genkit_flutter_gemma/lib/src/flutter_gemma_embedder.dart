import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:genkit/plugin.dart';

import 'backend_parse.dart';
import 'flutter_gemma_options.dart';
import 'flutter_gemma_runtime.dart';

/// Creates a Genkit [Embedder] action backed by flutter_gemma's embedding model.
///
/// The embedding model is lazily created on first call and cached for reuse.
Embedder<FlutterGemmaEmbedConfig> createFlutterGemmaEmbedder({
  required String name,
  required FlutterGemmaRuntime runtime,
}) {
  gemma.EmbeddingModel? cachedEmbedder;
  gemma.PreferredBackend? cachedBackend;

  return Embedder<FlutterGemmaEmbedConfig>(
    name: name,
    fn: (request, _) async {
      if (request == null) {
        throw GenkitException(
          'Embedder request cannot be null.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }

      // Parse optional backend preference.
      FlutterGemmaEmbedConfig? config;
      if (request.options != null) {
        try {
          config = FlutterGemmaEmbedConfig.fromJson(request.options!);
        } catch (e) {
          throw GenkitException(
            'Invalid embed options: $e',
            status: StatusCodes.INVALID_ARGUMENT,
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
