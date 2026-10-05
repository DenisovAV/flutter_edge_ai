import 'skill.dart';

/// Holds the set of available skills and which are currently *selected* (enabled
/// for the agent loop). Mirrors `EngineRegistry`/`EmbeddingRegistry` in spirit
/// but is per-agent state (selection toggled by the user in the skill manager),
/// not a global singleton.
///
/// Skills are keyed by [Skill.name]; adding a skill with an existing name
/// replaces it. Selection is tracked separately so toggling a skill off does
/// not drop it from the catalog.
class SkillRegistry {
  final _skills = <String, Skill>{};
  final _selected = <String>{};

  /// Add (or replace) a skill. Newly-added skills are NOT selected by default;
  /// pass [selected] true to select on add.
  void add(Skill skill, {bool selected = false}) {
    _skills[skill.name] = skill;
    if (selected) {
      _selected.add(skill.name);
    }
  }

  /// Add many skills at once. See [add].
  void addAll(Iterable<Skill> skills, {bool selected = false}) {
    for (final s in skills) {
      add(s, selected: selected);
    }
  }

  /// Remove a skill (and clear its selection) by name. No-op if absent.
  void remove(String name) {
    _skills.remove(name);
    _selected.remove(name);
  }

  /// Mark the skill named [name] as selected. No-op if [name] is unknown.
  void select(String name) {
    if (_skills.containsKey(name)) {
      _selected.add(name);
    }
  }

  /// Unselect the skill named [name]. No-op if not selected.
  void unselect(String name) => _selected.remove(name);

  /// Whether [name] is currently selected.
  bool isSelected(String name) => _selected.contains(name);

  /// Look up a skill by name; null if unknown.
  ///
  /// Exact match first, then a normalized fallback: small on-device models
  /// often echo a kebab-case skill id back as snake_case or with different
  /// casing (e.g. `interactive_map` for `interactive-map`) when they call
  /// `loadSkill`. Rather than fail those, we retry on a normalized key
  /// (lowercased, `_`→`-`) so a predictable model distortion doesn't read as
  /// "skill not found".
  Skill? get(String name) {
    final exact = _skills[name];
    if (exact != null) return exact;
    final wanted = _normalizeName(name);
    for (final skill in _skills.values) {
      if (_normalizeName(skill.name) == wanted) return skill;
    }
    return null;
  }

  static String _normalizeName(String name) =>
      name.trim().toLowerCase().replaceAll('_', '-');

  /// All known skills (selected or not), in insertion order.
  List<Skill> get all => List.unmodifiable(_skills.values);

  /// The currently-selected skills, in insertion order.
  List<Skill> getSelected() => List.unmodifiable(
    _skills.values.where((s) => _selected.contains(s.name)),
  );

  /// Builds the cheap two-stage discovery string injected into the system
  /// prompt: one `- name: description` line per selected skill. Only name +
  /// description go in the prompt — full [Skill.instructions] are pulled lazily
  /// by the agent loop's `loadSkill` tool, keeping context small with many
  /// skills. Returns an empty string when nothing is selected.
  String discoveryString() {
    final selected = getSelected();
    if (selected.isEmpty) return '';
    return selected.map((s) => '- ${s.name}: ${s.description}').join('\n');
  }

  /// Drop all skills and selection.
  void clear() {
    _skills.clear();
    _selected.clear();
  }
}
