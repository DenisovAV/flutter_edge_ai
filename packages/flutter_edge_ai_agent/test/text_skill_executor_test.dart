import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

Skill _skill(SkillType type) => Skill(
  name: 'kitchen-adventure',
  description: 'Persona skill.',
  instructions: 'Act as a dungeon master.',
  type: type,
);

void main() {
  group('TextSkillExecutor', () {
    final executor = TextSkillExecutor();

    test('canExecuteSkill is true only for textOnly skills', () {
      expect(executor.canExecuteSkill(_skill(SkillType.textOnly)), isTrue);
      expect(executor.canExecuteSkill(_skill(SkillType.js)), isFalse);
      expect(executor.canExecuteSkill(_skill(SkillType.intent)), isFalse);
      expect(executor.canExecuteSkill(_skill(SkillType.mcp)), isFalse);
    });

    test('canExecute (core String contract) bridges to the type', () {
      expect(executor.canExecute('text'), isTrue);
      expect(executor.canExecute('js'), isFalse);
      expect(executor.canExecute('unknown'), isFalse);
    });

    test(
      'execute is a no-op acknowledgement naming the active skill',
      () async {
        final result = await executor.execute(_skill(SkillType.textOnly), '');

        expect(result, isA<TextResult>());
        final text = (result as TextResult).text;
        expect(text, contains('kitchen-adventure'));
        expect(text.toLowerCase(), contains('active'));
      },
    );

    test('execute ignores data and secret (pure persona)', () async {
      final result = await executor.execute(
        _skill(SkillType.textOnly),
        '{"anything": true}',
        secret: 'sk-unused',
      );

      expect(result, isA<TextResult>());
    });

    test('priority is the in-package default of 0', () {
      expect(executor.priority, 0);
    });
  });
}
