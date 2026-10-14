import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show CancelToken, EmbeddingModel, PreferredBackend;

import 'island_catalog.dart';
import 'island_decider_preparation.dart';
import 'island_decider_recipe.dart';
import 'island_decider_store.dart';

/// [prepareIslandDecider]'s shape, so tests can hand the screen a scripted
/// decider.
typedef PrepareIslandDecider =
    Future<PreparedIslandDecider> Function({
      required EmbeddingModel embedder,
      required String model,
      required IslandDeciderRecipe recipe,
      required IslandDeciderStore store,
      required CancelToken cancelToken,
      required void Function(int done, int total) onProgress,
      String? embedderId,
    });

/// What the Embedding Models list left active, as this screen needs it: an
/// EmbeddingGemma 2 bundle to decide with, or why the screen cannot run.
sealed class TinyIslandSetup {
  const TinyIslandSetup();
}

/// An EmbeddingGemma 2 bundle of the example catalog is active.
final class TinyIslandEmbedderSetup extends TinyIslandSetup {
  const TinyIslandEmbedderSetup({
    required this.embedderName,
    required this.model,
    this.preferredBackend,
  });

  /// E.g. "EmbeddingGemma 2 Text (270M)".
  final String embedderName;

  /// The catalog entry's name (`embeddingGemma2Text270m`): what a stored
  /// decider is filed under. Each bundle keeps its own.
  final String model;

  /// What to ask `getActiveEmbedder` for: npu for a per-SoC bundle, null
  /// (CPU) for the others.
  final PreferredBackend? preferredBackend;
}

/// The screen cannot run; [message] says why, ready to show.
final class TinyIslandSetupProblem extends TinyIslandSetup {
  const TinyIslandSetupProblem(this.message, {this.modelListHelps = true});

  final String message;

  /// Whether choosing another model on the list fixes it. False for a
  /// browser without WebGPU: no model would load there.
  final bool modelListHelps;
}

/// Runs the Tiny Island screens' embedder work one job at a time.
///
/// Core's embedder is one per process: two screens that ask for it get the
/// same model. Every acquisition (with the decider prepared on it) and every
/// release goes through ONE lane, so a screen that was left while it was
/// still preparing releases its model before a newer screen asks core for
/// one — it can never close the model the newer screen is using.
final class IslandEmbedderLane {
  Future<void> _tail = Future<void>.value();

  /// Runs [job] after every job queued before it has finished (failed jobs
  /// included).
  Future<T> run<T>(Future<T> Function() job) {
    final result = _tail.then((_) => job());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// The app's one lane: there is one embedder per process.
final islandEmbedderLane = IslandEmbedderLane();

/// Everything the Tiny Island screen needs from outside. The app's wiring is
/// `tinyIslandAppDependencies()`; tests pass fakes.
final class TinyIslandDependencies {
  const TinyIslandDependencies({
    required this.readSetup,
    required this.loadEmbedder,
    required this.store,
    this.catalog = buildIslandCatalog,
    this.recipe = islandDeciderRecipe,
    this.prepare = prepareIslandDecider,
    this.embedderId,
    this.lane,
  });

  /// What the Embedding Models list left active.
  final Future<TinyIslandSetup> Function() readSetup;

  /// The embedder for [setup]: `FlutterEdgeAi.getActiveEmbedder` in the
  /// app. The screen owns what it returns and closes it when it leaves.
  final Future<EmbeddingModel> Function(TinyIslandEmbedderSetup setup)
  loadEmbedder;

  /// Where fitted deciders are kept between visits.
  final IslandDeciderStore store;

  /// The actions the Decider chooses among.
  final List<IslandAction> Function() catalog;

  /// How the Decider is fitted and calibrated over the catalog.
  final IslandDeciderRecipe Function(List<IslandAction> catalog) recipe;

  /// Loads the stored decider or fits one: [prepareIslandDecider] in the
  /// app.
  final PrepareIslandDecider prepare;

  /// Names the embedding space for `createDecider`/`loadDecider`. Null in
  /// the app: core names it by the installed file, its size and its
  /// backend. Test fakes (not built by core) need one.
  final String? embedderId;

  /// Null: the app's [islandEmbedderLane]. Tests pass their own.
  final IslandEmbedderLane? lane;
}
