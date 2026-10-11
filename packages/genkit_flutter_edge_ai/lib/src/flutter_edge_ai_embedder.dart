import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';

import 'backend_parse.dart';
import 'flutter_edge_ai_options.dart';
import 'flutter_edge_ai_runtime.dart';
import 'runtime_errors.dart';

/// Creates a Genkit [Embedder] action backed by flutter_edge_ai's embedding model.
///
/// The embedding model is lazily created on first call and cached for reuse
/// while it is open, was created for the same backend and is still the active
/// embedder. Texts are embedded as search queries unless the options say
/// `taskType: 'retrievalDocument'`, which is what documents being indexed
/// need: EmbeddingGemma prefixes the two differently.
Embedder<FlutterEdgeAiEmbedConfig> createFlutterEdgeAiEmbedder({
  required String name,
  required FlutterEdgeAiRuntime runtime,
}) {
  gemma.EmbeddingModel? cachedEmbedder;
  gemma.PreferredBackend? cachedBackend;
  String? cachedName;

  return Embedder<FlutterEdgeAiEmbedConfig>(
    name: name,
    customOptions: FlutterEdgeAiEmbedConfig.$schema,
    fn: (request, context) async {
      context.cancel?.throwIfCancelled();
      final options = await _parseEmbedOptions(request.options);
      final backend = parsePreferredBackend(options?.preferredBackend);
      final taskType = switch (options?.taskType) {
        null || 'retrievalQuery' => gemma.TaskType.retrievalQuery,
        'retrievalDocument' => gemma.TaskType.retrievalDocument,
        // The schema lists the two above; a value it lets through is a bug.
        final other => throw StateError('Unhandled taskType "$other"'),
      };

      // Extract text from each document before loading anything: a document
      // with no text would be embedded as an empty string.
      final texts = [
        for (final (index, doc) in request.input.indexed)
          _documentText(doc, index),
      ];

      // A closed embedder, one for another backend, or one that is no longer
      // the active embedder is loaded again.
      final activeName = runtime.activeEmbedderName;
      var embedder = cachedEmbedder;
      if (embedder == null ||
          embedder.isClosed ||
          cachedBackend != backend ||
          cachedName != activeName) {
        embedder = await withRuntimeErrors<gemma.EmbeddingModel>(
          'Could not load the on-device embedder',
          () => runtime.getActiveEmbedder(preferredBackend: backend),
          hasActiveModel: () => runtime.activeEmbedderName != null,
        );
        cachedEmbedder = embedder;
        cachedBackend = backend;
        cachedName = activeName;
      }
      context.cancel?.throwIfCancelled();

      final vectors = await embedder.generateEmbeddings(
        texts,
        taskType: taskType,
      );
      context.cancel?.throwIfCancelled();
      if (vectors.length != texts.length) {
        throw GenkitException(
          'The on-device embedder returned ${vectors.length} vectors for '
          '${texts.length} documents.',
          status: StatusCode.internal,
        );
      }

      return EmbedResponse(
        embeddings: [
          for (final (index, vector) in vectors.indexed)
            Embedding(
              embedding: vector,
              metadata: request.input[index].metadata,
            ),
        ],
      );
    },
  );
}

/// Reads the embed options, or throws INVALID_ARGUMENT for a value of the
/// wrong type or one the schema does not list.
Future<FlutterEdgeAiEmbedConfig?> _parseEmbedOptions(
  Map<String, dynamic>? options,
) async {
  if (options == null) return null;
  final errors = await FlutterEdgeAiEmbedConfig.$schema.validate(options);
  if (errors.isNotEmpty) {
    throw GenkitException(
      'Invalid embed options: '
      '${errors.map((e) => e.toErrorString()).join('; ')}',
      status: StatusCode.invalidArgument,
    );
  }
  return FlutterEdgeAiEmbedConfig.fromJson(options);
}

/// The text of a document, its text parts joined by spaces. A document with
/// no text part, empty or all images, say, is an INVALID_ARGUMENT: it would
/// be embedded as an empty string, and the embedder takes text only.
String _documentText(DocumentData doc, int index) {
  final buffer = StringBuffer();
  var hasText = false;
  for (final part in doc.content) {
    if (part.isText) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(part.text);
      hasText = true;
    }
  }
  if (!hasText) {
    throw GenkitException(
      'Document $index has no text part; the on-device embedder takes text '
      'only.',
      status: StatusCode.invalidArgument,
    );
  }
  return buffer.toString();
}
