import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';

import 'model.dart';

/// The skills this app ships in its own assets, one folder each:
/// `assets/skills/<name>/SKILL.md`, listed in `pubspec.yaml`.
const appSkillNames = ['packing-list'];

/// Reads every [appSkillNames] skill from this app's assets.
///
/// `AssetSkillSource` loads the skills `flutter_edge_ai_agent` bundles, from
/// the package's own assets; skills the app writes are read here, with the
/// same parser. A skill's `name:` must be its folder's name — that is how it
/// is found again once the model asks for it — so a mismatch is an error
/// here, not a skill that silently never loads.
Future<List<Skill>> loadAppSkills({AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final skills = <Skill>[];
  for (final name in appSkillNames) {
    final skill = parseSkillMd(
      await assets.loadString('assets/skills/$name/SKILL.md'),
    );
    if (skill.name != name) {
      throw StateError(
        'assets/skills/$name/SKILL.md is named "${skill.name}"; '
        'the name must match the folder.',
      );
    }
    skills.add(skill);
  }
  return skills;
}

/// Opens an agent on [model] with every skill this step knows.
///
/// The session's system prompt lists each selected skill by name and
/// description only. When a request fits one, the model calls `loadSkill`
/// to read its full instructions, and only then follows them — so twenty
/// skills cost twenty lines of prompt, not twenty documents.
Future<AgentSession> openAgent(InferenceModel model) async {
  final registry = SkillRegistry()
    ..addAll(await loadAppSkills(), selected: true);
  return AgentSession.fromModel(
    model,
    registry: registry,
    // One executor per kind of skill the registry holds. A text-only skill
    // is instructions and nothing to run, and TextSkillExecutor is what
    // answers for it.
    executors: [TextSkillExecutor()],
    modelType: Models.gemma4.modelType,
    maxOutputTokens: 512,
  );
}
