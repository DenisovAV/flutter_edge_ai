import 'island_catalog.dart';
import 'island_decider.dart';

/// The embedding model the Embedding Models list left active, as this screen
/// needs it. [problem] is set (ready to show) when there is none it can use.
final class TinyIslandSetup {
  const TinyIslandSetup({this.embedderName, this.profileId, this.problem})
    : assert((problem == null) == (embedderName != null && profileId != null));

  /// E.g. "EmbeddingGemma 2 Text (270M)".
  final String? embedderName;

  /// Its catalog embedding-space id: what the cached option vectors are keyed
  /// by.
  final String? profileId;

  /// Why this screen cannot run, e.g. "No embedding model is active".
  final String? problem;
}

/// Opens a decider over [catalog] for [setup]'s model, reporting [onProgress]
/// while it embeds the catalog; stops when [isCancelled] turns true.
typedef OpenIslandDecider =
    Future<IslandDecider> Function(
      TinyIslandSetup setup,
      List<IslandAction> catalog, {
      required void Function(int done, int total) onProgress,
      required bool Function() isCancelled,
    });

/// Everything the Tiny Island screen needs from outside. The app's wiring is
/// `tinyIslandAppDependencies()`; tests pass fakes.
final class TinyIslandDependencies {
  const TinyIslandDependencies({
    required this.readSetup,
    required this.openDecider,
    this.catalog = buildIslandCatalog,
  });

  /// What the Embedding Models list left active.
  final Future<TinyIslandSetup> Function() readSetup;

  final OpenIslandDecider openDecider;

  /// The actions the Decider chooses among.
  final List<IslandAction> Function() catalog;
}
