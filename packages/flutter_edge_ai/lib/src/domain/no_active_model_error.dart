/// Thrown when a model is asked for and none is installed and active: the
/// app has to install one first (`FlutterEdgeAi.installModel()` or
/// `installEmbedder()`).
///
/// A [StateError], so code catching that still catches this. The type is
/// what lets a caller tell "nothing installed yet", which can pass, from a
/// model that is installed and cannot run — no engine registered for it, say
/// — which cannot until the app changes.
class NoActiveModelError extends StateError {
  NoActiveModelError(super.message);
}
