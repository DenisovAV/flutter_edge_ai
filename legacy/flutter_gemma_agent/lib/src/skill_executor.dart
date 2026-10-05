import 'package:flutter_gemma/flutter_gemma.dart' show SkillExecutorProvider;

import 'skill.dart';
import 'skill_result.dart';

/// A pluggable way to run a [Skill] — the agent's flexibility seam.
///
/// One executor per skill mechanism (text-only persona, sandboxed JS, native
/// OS intent, MCP tool call). [SkillExecutor] `implements` the core
/// [SkillExecutorProvider] contract, so the very same instances can be:
///
///  1. registered through core via
///     `FlutterGemma.initialize(skillExecutors: [JsSkillExecutor(), …])`
///     (the recommended path — they land in core's `SkillExecutorRegistry`,
///     which `AgentSession.fromModel` reads when no explicit list is passed),
///     or
///  2. passed directly to `AgentSession.fromModel(executors: […])`.
///
/// Either way selection is a probe-chain exactly like `InferenceEngineProvider`:
/// the registered executor with the highest [priority] whose [canExecute] is
/// true wins (first-registered breaks ties). There is NO central type→executor
/// map — a third-party executor self-selects with zero changes elsewhere.
///
/// Core probes by the kebab-case type id ([canExecute] takes a `String`,
/// satisfying [SkillExecutorProvider]); inside the package use the type-safe
/// [canExecuteSkill] / [SkillType] check. The default [canExecute] bridges the
/// two via [SkillTypeId], so concrete executors only override [canExecuteSkill].
abstract class SkillExecutor implements SkillExecutorProvider {
  /// Human-readable name for diagnostics / progress UI (e.g. 'JsSkillExecutor').
  @override
  String get name;

  /// Selection precedence on overlap. In-package executors use 0; a third party
  /// raises this to take precedence for a skill both could handle.
  @override
  int get priority => 0;

  /// Type-safe selection probe — whether this executor can run [skill]
  /// (typically a single [SkillType] check). Concrete executors override THIS;
  /// [canExecute] (the core `String` contract) is derived from it.
  ///
  /// IMPORTANT: an implementation must select on [Skill.type] ALONE. When the
  /// core registry probes by type id (via [canExecute]), it passes a synthetic
  /// type-only [Skill]; reading any other field (e.g. [Skill.name],
  /// [Skill.metadata]) there throws. Selecting on the type is the contract.
  bool canExecuteSkill(Skill skill);

  /// Core [SkillExecutorProvider] contract: probe by the kebab-case type id
  /// (`'text'`/`'js'`/`'intent'`/`'mcp'`). Bridges to [canExecuteSkill] by
  /// resolving the id back to a [SkillType] (see [SkillTypeId]). Unknown ids
  /// resolve to no match. Override only if an executor needs to select on the
  /// raw id without a [Skill] — most don't.
  @override
  bool canExecute(String skillType) {
    final type = SkillTypeId.fromId(skillType);
    return type != null && canExecuteSkill(_TypeProbe(type));
  }

  /// Run [skill] with the model-supplied [dataJson] (the JSON-string argument
  /// the model passed to the tool), optionally with a runtime [secret] for
  /// `require-secret` skills. The secret is injected here and NEVER placed in
  /// the prompt.
  Future<SkillResult> execute(Skill skill, String dataJson, {String? secret});
}

/// A minimal [Skill] carrying only a [SkillType], used by the default
/// [SkillExecutor.canExecute] bridge so a type-only probe (`'js'` → does any
/// executor handle JS skills?) can reuse [SkillExecutor.canExecuteSkill]
/// without a fully-parsed skill. Executors must therefore probe on
/// [Skill.type] alone — which all in-package executors do.
class _TypeProbe implements Skill {
  _TypeProbe(this.type);

  @override
  final SkillType type;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
