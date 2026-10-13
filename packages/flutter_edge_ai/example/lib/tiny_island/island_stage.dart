import 'island_catalog.dart';

/// What the stage did with an action.
final class IslandOutcome {
  /// The action played; [note] says anything worth showing.
  const IslandOutcome.done([this.note]) : performed = true;

  /// The action could not play as asked, e.g. "The chest is already open."
  const IslandOutcome.declined(String this.note) : performed = false;

  final bool performed;
  final String? note;
}

/// Where actions play: the 3D island, or a recording fake in tests. Calls
/// are queued: each starts when the one before it has finished.
abstract interface class IslandStage {
  /// Plays [action]; completes when its animation has finished.
  Future<IslandOutcome> perform(IslandAction action);

  /// The Decider abstained: the character shrugs under a "?" bubble.
  Future<void> shrug();
}
