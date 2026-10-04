import 'dart:io';

import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

Skill _fixture(String name) => parseSkillMd(
  File('test/fixtures/skills/$name.SKILL.md').readAsStringSync(),
);

void main() {
  late Skill calculateHash;
  late Skill interactiveMap;
  late Skill sendEmail;
  late Skill kitchenAdventure;

  setUp(() {
    calculateHash = _fixture('calculate-hash');
    interactiveMap = _fixture('interactive-map');
    sendEmail = _fixture('send-email');
    kitchenAdventure = _fixture('kitchen-adventure');
  });

  group('SkillRegistry — add / select', () {
    test('add does not select by default', () {
      final reg = SkillRegistry()..add(calculateHash);

      expect(reg.all, hasLength(1));
      expect(reg.isSelected('calculate-hash'), isFalse);
      expect(reg.getSelected(), isEmpty);
    });

    test('add(selected: true) selects on add', () {
      final reg = SkillRegistry()..add(calculateHash, selected: true);

      expect(reg.isSelected('calculate-hash'), isTrue);
      expect(reg.getSelected(), [calculateHash]);
    });

    test('select / unselect toggles without dropping the skill', () {
      final reg = SkillRegistry()..add(calculateHash);

      reg.select('calculate-hash');
      expect(reg.isSelected('calculate-hash'), isTrue);

      reg.unselect('calculate-hash');
      expect(reg.isSelected('calculate-hash'), isFalse);
      // Still in the catalog.
      expect(reg.get('calculate-hash'), isNotNull);
    });

    test('select unknown skill is a no-op', () {
      final reg = SkillRegistry()..select('nope');
      expect(reg.isSelected('nope'), isFalse);
    });

    test('addAll adds many, get / all reflect them', () {
      final reg = SkillRegistry()
        ..addAll([calculateHash, sendEmail, kitchenAdventure]);

      expect(reg.all, hasLength(3));
      expect(reg.get('send-email'), sendEmail);
      expect(reg.get('missing'), isNull);
    });

    test('get tolerates snake_case / casing the model echoes back', () {
      // Small on-device models often call loadSkill with `calculate_hash` or
      // `Calculate-Hash` for the kebab-case `calculate-hash` — get() must still
      // resolve them (regression: was reported as "skill not found").
      final reg = SkillRegistry()..add(calculateHash);

      expect(reg.get('calculate_hash'), calculateHash);
      expect(reg.get('Calculate-Hash'), calculateHash);
      expect(reg.get('  calculate_hash  '), calculateHash);
      // A genuinely different name still misses.
      expect(reg.get('send-email'), isNull);
    });

    test('adding same name replaces and preserves selection toggling', () {
      final reg = SkillRegistry()..add(calculateHash, selected: true);
      final replaced = calculateHash.copyWith(
        description: 'Replaced description.',
      );

      reg.add(replaced);
      expect(reg.all, hasLength(1));
      expect(reg.get('calculate-hash')!.description, 'Replaced description.');
    });

    test('remove drops skill and its selection', () {
      final reg = SkillRegistry()..add(calculateHash, selected: true);

      reg.remove('calculate-hash');
      expect(reg.get('calculate-hash'), isNull);
      expect(reg.isSelected('calculate-hash'), isFalse);
      expect(reg.getSelected(), isEmpty);
    });
  });

  group('SkillRegistry — discoveryString', () {
    test('empty when nothing selected', () {
      final reg = SkillRegistry()..add(calculateHash); // not selected
      expect(reg.discoveryString(), isEmpty);
    });

    test('one line per selected skill: "- name: description"', () {
      final reg = SkillRegistry()
        ..add(calculateHash, selected: true)
        ..add(sendEmail, selected: true);

      expect(
        reg.discoveryString(),
        '- calculate-hash: Calculate the hash of a given text.\n'
        '- send-email: Send an email.',
      );
    });

    test('unselected skills are excluded from discovery', () {
      final reg = SkillRegistry()
        ..add(calculateHash, selected: true)
        ..add(interactiveMap) // not selected
        ..add(sendEmail, selected: true);

      final lines = reg.discoveryString().split('\n');
      expect(lines, hasLength(2));
      expect(reg.discoveryString(), isNot(contains('interactive-map')));
    });

    test('discovery carries ONLY name + description, never instructions', () {
      final reg = SkillRegistry()..add(kitchenAdventure, selected: true);

      final discovery = reg.discoveryString();
      expect(discovery, startsWith('- kitchen-adventure:'));
      // The long instructions body must not leak into the discovery prompt.
      expect(discovery, isNot(contains('Head Chef')));
    });
  });

  group('SkillRegistry — clear', () {
    test('clear drops everything', () {
      final reg = SkillRegistry()
        ..add(calculateHash, selected: true)
        ..add(sendEmail, selected: true);

      reg.clear();
      expect(reg.all, isEmpty);
      expect(reg.getSelected(), isEmpty);
    });
  });
}
