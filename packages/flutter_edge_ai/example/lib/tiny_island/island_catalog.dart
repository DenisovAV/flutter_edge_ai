import 'island_actions_data.dart';
import 'island_vocabulary.dart';

/// One option the Decider chooses among: an id such as `walk_to(tree)` or
/// `jump`, a short description, and the example phrasings it learns from.
/// [verb] and [thing] are what the stage animates.
final class IslandAction {
  const IslandAction({
    required this.verb,
    this.thing,
    required this.description,
    required this.examples,
  });

  final IslandVerb verb;
  final IslandThing? thing;
  final String description;
  final List<String> examples;

  /// `verb(thing)` or `verb`: unique in the catalog.
  String get id => switch (thing) {
    final thing? => '${verb.id}(${thing.name})',
    null => verb.id,
  };

  /// What the Decider's option carries besides its id and description.
  Map<String, String> get metadata => {
    'verb': verb.id,
    if (thing case final thing?) 'thing': thing.name,
  };

  @override
  String toString() => id;
}

/// Every action on the island, in a stable order: generic verbs × things,
/// then the per-thing verbs, then the character, world and camera actions.
List<IslandAction> buildIslandCatalog() {
  String fill(String template, IslandThing thing) {
    final words = islandThingWords[thing]!;
    return template
        .replaceAll('{t2}', words.en2)
        .replaceAll('{t}', words.en)
        .replaceAll('{acc}', words.acc)
        .replaceAll('{dat}', words.dat)
        .replaceAll('{gen}', words.gen)
        .replaceAll('{ins}', words.ins);
  }

  return [
    for (final MapEntry(key: verb, value: phrases)
        in genericVerbPhrases.entries)
      for (final thing in IslandThing.values)
        IslandAction(
          verb: verb,
          thing: thing,
          description: fill(phrases.description, thing),
          examples: [for (final e in phrases.examples) fill(e, thing)],
        ),
    for (final (verb, thing, phrases) in thingVerbPhrases)
      IslandAction(
        verb: verb,
        thing: thing,
        description: phrases.description,
        examples: phrases.examples,
      ),
    for (final MapEntry(key: verb, value: phrases) in globalVerbPhrases.entries)
      IslandAction(
        verb: verb,
        description: phrases.description,
        examples: phrases.examples,
      ),
  ];
}
