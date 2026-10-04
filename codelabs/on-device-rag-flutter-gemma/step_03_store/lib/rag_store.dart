import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:path_provider/path_provider.dart';

import 'model.dart';
import 'recipes.dart';

/// Everything this app does with the vector store, in one place.
///
/// Step 2 kept the vectors in a `Map` inside a widget. Three things were wrong
/// with that, and none of them are fixed by a bigger `Map`:
///
/// 1. **It does not survive a restart.** Close the app and the index is gone.
///    Re-embedding twelve recipes is a few seconds; re-embedding a real corpus
///    on every cold start is not a thing you can ship.
/// 2. **It costs more memory than you think.** A Dart `double` is a *float64*,
///    so one 768-dimension vector is 768 × 8 = 6 KB — not the 3 KB the model
///    actually emits. Ten thousand documents is 60 MB of Dart heap sitting
///    beside an LLM that already wants a gigabyte or two.
/// 3. **There is nothing to filter on.** "Italian, under 30 minutes" has to
///    happen either before the search (and then it is not a nearest-neighbour
///    search any more) or after it (and then the top-3 can come back empty).
///
/// A vector store fixes all three at once, and the reason is the same for all
/// three: the vectors stop being a Dart object and become rows in a database
/// that knows they are vectors.
class RagStore {
  /// sqlite-vec wants a `.db` FILE path. On web there is no file system to
  /// put it on — the store registers an IndexedDB-backed VFS under this name
  /// instead, so the bare name is the whole path.
  static Future<String> databasePath() async {
    const name = 'recipes.db';
    if (kIsWeb) return name;
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$name';
  }

  /// Open the store. Idempotent in the sense that matters: an index written by
  /// a previous run is still there afterwards.
  static Future<VectorStoreStats> open() async {
    await FlutterEdgeAi.rag.initialize(await databasePath());
    return FlutterEdgeAi.rag.stats();
  }

  /// Embed every recipe and write it in.
  ///
  /// `addDocumentWithEmbedding` takes a vector you already have.
  /// `addDocument(content:)` would embed for you, one document per call —
  /// fine for one, wasteful for twelve, because each call would set up the
  /// embedding worker again.
  static Future<void> index({void Function(String)? onStatus}) async {
    onStatus?.call('Embedding ${kRecipes.length} recipes...');

    final embedder = await FlutterEdgeAi.getActiveEmbedder();
    final vectors = await embedder.generateEmbeddings(
      kRecipes.map((r) => r.text).toList(),
      // Documents, not queries — see the note in Step 2. `searchSimilar`
      // below embeds the query with the *other* prefix automatically, so the
      // two halves of the asymmetry stay matched without you tracking it.
      taskType: TaskType.retrievalDocument,
    );

    onStatus?.call('Writing ${kRecipes.length} rows...');
    for (var i = 0; i < kRecipes.length; i++) {
      final r = kRecipes[i];
      await FlutterEdgeAi.rag.addDocumentWithEmbedding(
        id: r.id,
        content: r.text,
        embedding: vectors[i],
        // Metadata rides along as a JSON string. Step 4 declares which of
        // these keys are *filterable* — until then they are just carried.
        metadata: jsonEncode({
          'title': r.title,
          'cuisine': r.cuisine,
          'minutes': r.minutes,
          'vegetarian': r.vegetarian,
        }),
      );
    }

    // Native sqlite-vec has already written every row by the time the calls
    // above returned, so this is a no-op there. On web it drains the
    // IndexedDB VFS and waits for it. Step 6 is about why that difference
    // exists and when it bites.
    await FlutterEdgeAi.rag.flush();
    onStatus?.call('Indexed ${kRecipes.length} recipes.');
  }

  /// Search. The query is embedded for you — with `retrievalQuery`, which is
  /// the prefix that matches the `retrievalDocument` used at index time.
  static Future<List<RetrievalResult>> search(
    String query, {
    int topK = 3,
    double threshold = 0.3,
  }) async {
    // Nothing indexed means nothing to ground with — and searching an empty
    // store would still need the embedding runtime below. Answer early.
    final stats = await FlutterEdgeAi.rag.stats();
    if (stats.documentCount == 0) return const [];

    // `searchSimilar(query:)` embeds the query for you, and embedding needs a
    // live embedding model. A fresh launch has none: open() restores the
    // DATABASE, not the runtime — the index survives the process, the model
    // does not. Without this line the first question after a restart throws a
    // StateError instead of being answered, which is exactly the case the
    // persisted index exists for.
    //
    // getActiveEmbedder() is idempotent: after the first call it hands back
    // the model it already built.
    await FlutterEdgeAi.getActiveEmbedder();

    return FlutterEdgeAi.rag.searchSimilar(
      query: query,
      topK: topK,
      // Cosine similarity, so 1.0 is identical and 0.0 is unrelated. Without
      // a threshold a search always returns `topK` rows, however bad — which
      // reads as "found something" to every caller downstream.
      threshold: threshold,
    );
  }

  static Future<void> clear() => FlutterEdgeAi.rag.clear();

  /// Look up the recipe behind a hit. The store returns the id it was given,
  /// which is exactly why [Recipe.id] has to be stable across re-indexes.
  static Recipe? recipeFor(RetrievalResult r) {
    for (final recipe in kRecipes) {
      if (recipe.id == r.id) return recipe;
    }
    return null;
  }
}

/// Installs the embedding model. Unchanged from Step 2, moved here so the page
/// below is only about the store.
Future<void> installEmbedder({void Function(double)? onProgress}) {
  const e = Embedders.embeddingGemma;
  return FlutterEdgeAi.installEmbedder()
      .modelFromNetwork(e.modelUrl, token: hfToken.isEmpty ? null : hfToken)
      .tokenizerFromNetwork(
        e.tokenizerUrl,
        token: hfToken.isEmpty ? null : hfToken,
      )
      .withModelProgress((p) => onProgress?.call(p / 100))
      .install();
}
