import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path_provider/path_provider.dart';

import 'model.dart';
import 'recipes.dart';

/// App-owned retrieval service.
///
/// [open] is single-flight: every widget shares one [RagIndex], which matters on
/// Web because SQLite holds an exclusive Web Lock for the location while open.
/// The index owns the vector store; this service owns and disposes the index.
class RagStore {
  RagStore({
    required this.databaseName,
    this.filterSchema = FilterSchema.empty,
  });

  final String databaseName;
  final FilterSchema filterSchema;
  final FlutterEdgeAiRag _rag = FlutterEdgeAiRag(
    providers: const [SqliteVectorStoreProvider()],
  );

  Future<RagIndex>? _opening;
  Future<void>? _disposing;
  bool _disposeRequested = false;

  Future<String> databasePath() async {
    if (kIsWeb) return databaseName;
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$databaseName';
  }

  /// Whether the embedder this index searches with is installed yet.
  ///
  /// `FlutterEdgeAiRag.open()` pins the embedder that is active at the moment
  /// it runs, for the life of the index. Opened before `installEmbedder()`, it
  /// pins none, and every `addText` and `searchText` after that throws. So
  /// install the embedder first and open the index second — this store
  /// refuses to open until this is true.
  bool get embedderInstalled => FlutterEdgeAi.hasActiveEmbedder();

  /// Opens this app's one index, or joins the in-flight open.
  Future<VectorStoreStats> open() async => (await _index()).stats();

  Future<RagIndex> _index() {
    if (_disposeRequested) {
      throw StateError('RagStore is disposing or already disposed.');
    }
    if (!embedderInstalled) {
      throw StateError(
        'Install the embedder before opening the index: open() pins the '
        'embedder that is active when it runs.',
      );
    }
    return _opening ??= _openOnce();
  }

  Future<RagIndex> _openOnce() async {
    try {
      final embedder = Embedders.embeddingGemma;
      final index = await _rag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: await databasePath(),
          filterSchema: filterSchema,
        ),
        // Batch indexing below writes raw vectors first, so bind the new store
        // explicitly. The same ID lets searchText borrow the active core model.
        embeddingProfile: EmbeddingProfile(
          id: embedder.profileId,
          dimension: 768,
        ),
        activeEmbedderProfileId: embedder.profileId,
      );
      if (_disposeRequested) {
        await index.dispose();
        throw StateError('RagStore was disposed while it was opening.');
      }
      return index;
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  /// Batch-embeds the corpus, then writes profile-compatible vectors.
  Future<void> index({void Function(String)? onStatus}) async {
    final ragIndex = await _index();
    onStatus?.call('Embedding ${kRecipes.length} recipes...');

    final embedder = await FlutterEdgeAi.getActiveEmbedder();
    final vectors = await embedder.generateEmbeddings(
      kRecipes.map((recipe) => recipe.text).toList(),
      taskType: TaskType.retrievalDocument,
    );

    onStatus?.call('Writing ${kRecipes.length} rows...');
    for (var i = 0; i < kRecipes.length; i++) {
      final recipe = kRecipes[i];
      await ragIndex.addVector(
        id: recipe.id,
        content: recipe.text,
        embedding: vectors[i],
        metadata: jsonEncode({
          'title': recipe.title,
          'cuisine': recipe.cuisine,
          'minutes': recipe.minutes,
          'vegetarian': recipe.vegetarian,
        }),
      );
    }

    // Required for qdrant, a durability fence on Web SQLite, and a no-op on
    // native SQLite. Keeping it unconditional makes provider swaps safe.
    await ragIndex.flush();
    onStatus?.call('Indexed ${kRecipes.length} recipes.');
  }

  Future<List<RetrievalResult>> search(
    String query, {
    int topK = 3,
    double threshold = 0.3,
    Filter? filter,
  }) async {
    // `index()` installs the embedder before it writes a row, so with none
    // installed there is nothing to find — and opening now would pin "no
    // embedder" for the life of the index.
    if (!embedderInstalled) return const [];
    final ragIndex = await _index();
    final stats = await ragIndex.stats();
    if (stats.documentCount == 0) return const [];

    return ragIndex.searchText(
      query: query,
      topK: topK,
      threshold: threshold,
      filter: filter,
    );
  }

  Future<VectorStoreStats> stats() async => (await _index()).stats();

  Future<void> clear() async {
    final index = await _index();
    await index.clear();
    await index.flush();
  }

  /// Dispose this before FlutterEdgeAi.dispose(), whose embedder the index borrows.
  Future<void> dispose() => _disposing ??= _disposeOnce();

  Future<void> _disposeOnce() async {
    _disposeRequested = true;
    final opening = _opening;
    if (opening == null) return;
    try {
      final index = await opening;
      await index.dispose();
    } on StateError {
      // A failed/aborted open owns no live index.
    }
  }

  /// Looks up the recipe behind a hit using its stable corpus id.
  static Recipe? recipeFor(RetrievalResult result) {
    for (final recipe in kRecipes) {
      if (recipe.id == result.id) return recipe;
    }
    return null;
  }
}

/// Installs the embedding model. The URLs are revision-pinned because changing
/// bytes at one persistent location would invalidate its embedding profile.
Future<void> installEmbedder({void Function(double)? onProgress}) {
  const embedder = Embedders.embeddingGemma;
  return FlutterEdgeAi.installEmbedder()
      .modelFromNetwork(
        embedder.modelUrl,
        token: hfToken.isEmpty ? null : hfToken,
      )
      .tokenizerFromNetwork(
        embedder.tokenizerUrl,
        token: hfToken.isEmpty ? null : hfToken,
      )
      .withModelProgress((progress) => onProgress?.call(progress / 100))
      .install();
}

/// Turns the page's controls into backend-neutral metadata conditions.
Filter? buildFilter({
  Set<String> cuisines = const {},
  int? maxMinutes,
  bool vegetarianOnly = false,
}) {
  final must = <Condition>[
    if (cuisines.isNotEmpty)
      FieldMatchAny(key: 'cuisine', values: cuisines.toList()),
    if (maxMinutes != null)
      FieldRange(key: 'minutes', lte: maxMinutes.toDouble()),
    if (vegetarianOnly) FieldEquals(key: 'vegetarian', value: true),
  ];
  return must.isEmpty ? null : Filter(must: must);
}
