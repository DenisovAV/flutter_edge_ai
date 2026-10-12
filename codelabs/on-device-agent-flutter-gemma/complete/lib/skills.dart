import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';

import 'model.dart';

/// The skills this app ships in its own assets, one folder each:
/// `assets/skills/<name>/SKILL.md`, listed in `pubspec.yaml`.
const appSkillNames = ['packing-list', 'tip-split'];

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
  'calculate-hash',
  'qr-code',
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
  final bundled = AssetSkillSource(names: packageSkillNames);
  final registry = SkillRegistry()
    ..addAll(await loadAppSkills(), selected: true)
    ..addAll(await bundled.load(), selected: true);
  return AgentSession.fromModel(
    model,
    registry: registry,
    // One executor per kind of skill the registry holds: `run_js` skills go
    // to JsSkillExecutor, `run_intent` ones to NativeIntentExecutor, and
    // text-only ones to TextSkillExecutor.
    executors: [
      TextSkillExecutor(),
      NativeIntentExecutor(),
      JsSkillExecutor(sourceFor: (skill) => _jsSourceFor(skill, bundled)),
    ],
    modelType: Models.gemma4.modelType,
    maxOutputTokens: 512,
  );
}

/// Where a JS skill's page is: in the package's assets for a skill the
/// package bundles, in this app's for one the app wrote.
///
/// The executor serves the page, and the files next to it, from a server on
/// 127.0.0.1 inside the app and runs it in a headless webview; nothing goes
/// over the network. That server is why Android needs cleartext traffic to
/// 127.0.0.1 and macOS the `network.server` entitlement.
JsSkillSource _jsSourceFor(Skill skill, AssetSkillSource bundled) =>
    packageSkillNames.contains(skill.name)
    ? bundled.jsSkillSourceFor(skill)
    : JsSkillSource.asset(
        'assets/skills/${skill.name}/scripts/${skill.scriptName}',
      );
