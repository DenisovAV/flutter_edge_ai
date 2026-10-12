import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';

/// The skills this app ships in its own assets, one folder each:
/// `assets/skills/<name>/SKILL.md`, listed in `pubspec.yaml`.
const appSkillNames = ['packing-list'];

/// Skills `flutter_edge_ai_agent` bundles, picked by name.
///
/// Each is a SKILL.md whose instructions tell the model to call `runIntent`
/// with one of the package's fixed intents. The intent opens an OS surface —
/// the calendar's event editor, the mail composer — and the user confirms it
/// there: the model fills the form, it never presses Send.
const packageSkillNames = [
  'get-current-time',
  'create-calendar-event',
  'send-email',
];

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
    final path = 'assets/skills/$name/SKILL.md';
    final Skill skill;
    try {
      skill = parseSkillMd(await assets.loadString(path));
    } catch (error) {
      // Name the file: "missing field" alone does not say which skill.
      throw StateError('$path could not be read: $error');
    }
    if (skill.name != name) {
      throw StateError(
        '$path is named "${skill.name}"; the name must match the folder.',
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
///
/// [modelType] is the model's family: it decides how tool calls are written
/// and read, so the wrong one turns every turn into plain text.
Future<AgentSession> openAgent(
  InferenceModel model, {
  required ModelType modelType,
}) async {
  final bundled = AssetSkillSource(names: packageSkillNames);
  final registry = SkillRegistry()
    ..addAll(await loadAppSkills(), selected: true)
    ..addAll(await bundled.load(), selected: true);
  return AgentSession.fromModel(
    model,
    registry: registry,
    // One executor per kind of skill the registry holds. A skill whose
    // instructions say `run_intent` is routed to NativeIntentExecutor; a
    // text-only one to TextSkillExecutor.
    executors: [TextSkillExecutor(), NativeIntentExecutor()],
    modelType: modelType,
    maxOutputTokens: 512,
  );
}
