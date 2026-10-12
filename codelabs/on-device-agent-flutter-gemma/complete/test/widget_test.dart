import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_device_agent/download_page.dart';
import 'package:on_device_agent/model.dart';
import 'package:on_device_agent/skills.dart';
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';

void main() {
  // Real async for the asset tests: rootBundle caches each load, and a
  // future cached inside one testWidgets' fake-async zone never completes in
  // the next one's.
  TestWidgetsFlutterBinding.ensureInitialized();

  // `isModelInstalled` is keyed by file name. `install()` skips bytes it
  // already has, so a name that drifts from its URL does not re-download — it
  // strands the app on a download screen the gate is never satisfied by.
  test('the model id matches the last segment of its URL', () {
    const model = Models.gemma4;
    expect(model.fileName, model.url.split('/').last, reason: model.label);
  });

  testWidgets('the download screen offers the model before any plugin call', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadPage(model: Models.gemma4, onInstalled: () {}),
      ),
    );
    expect(find.text('Gemma 4 E2B'), findsOneWidget);
    expect(find.text('Download model'), findsOneWidget);
  });

  // A SKILL.md that does not parse, or whose name is not its folder, is a
  // skill the model can list but never load. Catch it here, not mid-chat.
  test('every skill the app ships parses, under its folder name', () async {
    final skills = await loadAppSkills();
    expect(skills.map((s) => s.name), appSkillNames);
    for (final skill in skills) {
      expect(skill.description, isNotEmpty, reason: skill.name);
      expect(skill.instructions, isNotEmpty, reason: skill.name);
    }
    expect(
      {for (final s in skills) s.name: s.type},
      {'packing-list': SkillType.textOnly, 'tip-split': SkillType.js},
    );
  });

  // A JS skill whose page is not in the bundle parses fine and fails only
  // when the model calls it. Load the page the executor will ask for.
  test('every app JS skill ships the page it runs', () async {
    for (final skill in await loadAppSkills()) {
      if (skill.type != SkillType.js) continue;
      final page = await rootBundle.loadString(
        'assets/skills/${skill.name}/scripts/${skill.scriptName}',
      );
      expect(page, contains('index.js'), reason: skill.name);
    }
  });

  // The bundled skills come out of the package's own assets, under a
  // `packages/flutter_edge_ai_agent/` prefix. A name that is not one of them
  // fails here with the reason, instead of an agent with a missing skill.
  test('the bundled skills this step picks load', () async {
    final skills = await AssetSkillSource(names: packageSkillNames).load();
    expect(skills.map((s) => s.name), packageSkillNames);
    expect(skills.map((s) => s.type).toSet(), {SkillType.intent, SkillType.js});
  });
}
