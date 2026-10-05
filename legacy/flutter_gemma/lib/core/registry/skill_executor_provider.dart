/// A pluggable skill executor — the seam between core and the opt-in
/// `flutter_gemma_agent` package's agentic "skills" runtime.
///
/// Core stays dependency-free: it knows nothing about `webview_flutter`,
/// `url_launcher`, calendar/notification plugins, or the agent's `Skill` /
/// `SkillResult` types. It only holds this minimal contract so it can plumb the
/// `skillExecutors:` list registered via `FlutterGemma.initialize` and probe it
/// by skill *type* (a kebab-case string such as `'text'`, `'js'`, `'intent'`,
/// `'mcp'`).
///
/// The concrete `SkillExecutor` base class and the sealed `SkillResult` value
/// types (Text/Image/Widget/Webview/Error) live in `flutter_gemma_agent`, where
/// they `implements SkillExecutorProvider`. Selection mirrors
/// [InferenceEngineProvider] / [EmbeddingBackendProvider]: the registry probes
/// the registered executors and the highest-[priority] one whose [canExecute]
/// returns true for the skill type wins (first-registered breaks ties).
///
/// Passed to `FlutterGemma.initialize` via `skillExecutors:`.
abstract class SkillExecutorProvider {
  /// Human-readable name for diagnostics / error messages (e.g. 'JsSkill').
  String get name;

  /// Selection precedence on overlap. In-package executors use 0; a third party
  /// raises this to take precedence for a skill type both could handle.
  int get priority => 0;

  /// Whether this executor can run a skill of [skillType] (the kebab-case skill
  /// type id, e.g. `'text'`, `'js'`, `'intent'`, `'mcp'`). Probed by the
  /// registry. Kept type-agnostic (a plain String) so core carries no `Skill`
  /// type and no agent-package dependency.
  bool canExecute(String skillType);
}
