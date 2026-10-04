import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('agentTools', () {
    test('exposes the four built-in tools in order', () {
      expect(agentTools.map((t) => t.name).toList(), [
        'loadSkill',
        'runSkill',
        'runIntent',
        'runMcp',
      ]);
    });

    test('names match AgentToolNames constants', () {
      expect(loadSkillTool.name, AgentToolNames.loadSkill);
      expect(runSkillTool.name, AgentToolNames.runSkill);
      expect(runIntentTool.name, AgentToolNames.runIntent);
      expect(runMcpTool.name, AgentToolNames.runMcp);
    });

    test('loadSkill requires skillName', () {
      final props = loadSkillTool.parameters['properties'] as Map;
      expect(props.keys, contains('skillName'));
      expect(loadSkillTool.parameters['required'], ['skillName']);
    });

    test('runSkill takes skillName + data', () {
      final props = runSkillTool.parameters['properties'] as Map;
      expect(props.keys, containsAll(['skillName', 'data']));
      expect(runSkillTool.parameters['required'], ['skillName', 'data']);
    });

    test('runSkill does not ask the model for a scriptName it cannot use', () {
      // Gallery's runJs schema has a required `scriptName`, and this tool
      // mirrored it — but AgentLoop resolves the script from the registered
      // Skill's own SKILL.md (`Skill.scriptName`), never from the call args.
      // Declaring it required made the model invent a filename to fill a field
      // that was then dropped. Keep it out of both lists.
      final props = runSkillTool.parameters['properties'] as Map;
      expect(props.keys, isNot(contains('scriptName')));
      expect(
        runSkillTool.parameters['required'],
        isNot(contains('scriptName')),
      );
    });

    test('runIntent takes intent + parameters', () {
      final props = runIntentTool.parameters['properties'] as Map;
      expect(props.keys, containsAll(['intent', 'parameters']));
    });

    test('runMcp takes toolName + input', () {
      final props = runMcpTool.parameters['properties'] as Map;
      expect(props.keys, containsAll(['toolName', 'input']));
    });
  });

  group('AgentSession.buildSystemPrompt', () {
    test('substitutes the selected-skills discovery list into __SKILLS__', () {
      final registry = SkillRegistry()
        ..add(
          const Skill(
            name: 'calc',
            description: 'Calculate stuff.',
            instructions: 'body',
            type: SkillType.js,
          ),
          selected: true,
        );

      final prompt = AgentSession.buildSystemPrompt(registry);

      expect(prompt, isNot(contains('__SKILLS__')));
      expect(prompt, contains('- calc: Calculate stuff.'));
      expect(prompt, contains('loadSkill'));
    });

    test('empty registry leaves no placeholder and no skills', () {
      final prompt = AgentSession.buildSystemPrompt(SkillRegistry());
      expect(prompt, isNot(contains('__SKILLS__')));
    });

    test('custom template is honored', () {
      final registry = SkillRegistry()
        ..add(
          const Skill(
            name: 's',
            description: 'd',
            instructions: 'b',
            type: SkillType.textOnly,
          ),
          selected: true,
        );

      final prompt = AgentSession.buildSystemPrompt(
        registry,
        systemPromptTemplate: 'Skills:\n__SKILLS__\nEnd.',
      );
      expect(prompt, 'Skills:\n- s: d\nEnd.');
    });
  });
}
