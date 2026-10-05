/// How a [Skill] is executed. Inferred from the SKILL.md body's tool mention by
/// [parseSkillMd] (`run_js` → [js], `run_intent` → [intent], `run_mcp` → [mcp],
/// otherwise [textOnly]) and used by the executor probe-chain to route a skill
/// to the matching [SkillExecutor].
enum SkillType {
  /// Pure prompt / persona — no tool, no code, no risk. Just instructions fed
  /// to the model (e.g. Gallery's `kitchen-adventure`).
  textOnly,

  /// JavaScript run in a sandboxed webview via the `run_js` tool. The script
  /// exposes `window.ai_edge_gallery_get_result(data, secret)`.
  js,

  /// Native OS intent (email / calendar / notification / …) via the
  /// `run_intent` tool. No foreign code — a whitelist of actions behind OS/user
  /// confirmation.
  intent,

  /// A tool call against a remote MCP (Model Context Protocol) server via the
  /// `run_mcp` tool.
  mcp,
}

/// Maps [SkillType] to/from the kebab-case id strings the core
/// `SkillExecutorProvider.canExecute(String)` contract uses (`'text'`, `'js'`,
/// `'intent'`, `'mcp'`). This is the bridge that lets the package's rich
/// `canExecute(Skill)` executors satisfy core's type-agnostic provider seam, so
/// `FlutterGemma.initialize(skillExecutors: [...])` works without core ever
/// depending on the [Skill] type.
extension SkillTypeId on SkillType {
  /// The core-facing id (note: [textOnly] → `'text'`, not `'textOnly'`).
  String get id => switch (this) {
    SkillType.textOnly => 'text',
    SkillType.js => 'js',
    SkillType.intent => 'intent',
    SkillType.mcp => 'mcp',
  };

  /// Parse a core id back to a [SkillType]; null if unknown.
  static SkillType? fromId(String id) => switch (id) {
    'text' => SkillType.textOnly,
    'js' => SkillType.js,
    'intent' => SkillType.intent,
    'mcp' => SkillType.mcp,
    _ => null,
  };
}

/// Optional `metadata:` block from a SKILL.md frontmatter.
///
/// All fields are optional; a skill with no `metadata:` block parses to an
/// instance with [homepage] null, [requireSecret] false, and
/// [secretDescription] null.
class SkillMetadata {
  const SkillMetadata({
    this.homepage,
    this.requireSecret = false,
    this.secretDescription,
  });

  /// `metadata.homepage` — where the skill comes from / its docs. May be null.
  final String? homepage;

  /// `metadata.require-secret` — whether the skill needs an API key/secret
  /// supplied at runtime (injected into the executor, never into the prompt).
  final bool requireSecret;

  /// `metadata.require-secret-description` — human-readable hint on how to
  /// obtain the secret. May be null.
  final String? secretDescription;

  /// True when this metadata carries no information (the default/empty case).
  bool get isEmpty =>
      homepage == null && !requireSecret && secretDescription == null;

  @override
  String toString() =>
      'SkillMetadata(homepage: $homepage, '
      'requireSecret: $requireSecret, secretDescription: $secretDescription)';
}

/// A parsed agent skill: identity ([name]/[description]) the model uses to pick
/// the skill, the full [instructions] (the SKILL.md markdown body) loaded
/// on demand, the inferred [type], and optional [metadata].
///
/// Gallery-compatible: a SKILL.md from the google-ai-edge/gallery catalog parses
/// into this model unmodified (see [parseSkillMd]).
///
/// Identity semantics: this is a reference type, not a value type — [copyWith]
/// builds a new object, but two `Skill`s with the same fields are NOT `==`.
/// Skills are tracked by [name] (a string key) in [SkillRegistry], never by
/// object equality, so no value `==`/`hashCode` is defined.
class Skill {
  const Skill({
    required this.name,
    required this.description,
    required this.instructions,
    required this.type,
    this.metadata = const SkillMetadata(),
    this.scriptName = 'index.html',
  });

  /// Kebab-case identifier from frontmatter `name:` (e.g. `calculate-hash`).
  final String name;

  /// One-line summary from frontmatter `description:`. This is the ONLY skill
  /// text put in the discovery prompt — see [SkillRegistry.discoveryString].
  final String description;

  /// The markdown body (everything after the frontmatter). Pulled into the
  /// prompt lazily by the agent loop's `loadSkill` tool (two-stage discovery).
  final String instructions;

  /// How this skill runs, inferred from [instructions].
  final SkillType type;

  /// Optional frontmatter `metadata:` block.
  final SkillMetadata metadata;

  /// For [SkillType.js] skills, the script file to run (the `run_js` tool's
  /// `scriptName`). Defaults to `index.html` (Gallery's default) when the body
  /// does not name one.
  final String scriptName;

  /// Convenience: whether this skill needs a runtime secret.
  bool get requireSecret => metadata.requireSecret;

  Skill copyWith({
    String? name,
    String? description,
    String? instructions,
    SkillType? type,
    SkillMetadata? metadata,
    String? scriptName,
  }) {
    return Skill(
      name: name ?? this.name,
      description: description ?? this.description,
      instructions: instructions ?? this.instructions,
      type: type ?? this.type,
      metadata: metadata ?? this.metadata,
      scriptName: scriptName ?? this.scriptName,
    );
  }

  @override
  String toString() => 'Skill(name: $name, type: $type)';
}
