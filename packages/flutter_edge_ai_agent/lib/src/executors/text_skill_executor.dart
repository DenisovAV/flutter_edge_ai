import '../skill.dart';
import '../skill_executor.dart';
import '../skill_result.dart';

/// Executor for [SkillType.textOnly] skills — pure persona / prompt skills with
/// no tool, no code, and no side effects (e.g. Gallery's `kitchen-adventure`).
///
/// Zero dependencies. The "execution" is a no-op acknowledgement: a text-only
/// skill shaped the model the moment its instructions were loaded (via the
/// `loadSkill` tool in the agent loop), so there is nothing to run here. The
/// model has already absorbed the persona; this executor just confirms back to
/// the model that the skill is active so the loop can continue cleanly.
class TextSkillExecutor extends SkillExecutor {
  @override
  String get name => 'TextSkillExecutor';

  @override
  bool canExecuteSkill(Skill skill) => skill.type == SkillType.textOnly;

  @override
  Future<SkillResult> execute(
    Skill skill,
    String dataJson, {
    String? secret,
  }) async {
    return TextResult(
      'Skill "${skill.name}" is active. Continue following its instructions.',
    );
  }
}
