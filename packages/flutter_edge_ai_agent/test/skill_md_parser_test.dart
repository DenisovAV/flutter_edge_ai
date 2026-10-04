import 'dart:io';

import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

String _fixture(String name) =>
    File('test/fixtures/skills/$name.SKILL.md').readAsStringSync();

void main() {
  group('parseSkillMd — Gallery fixtures', () {
    test('calculate-hash → js (run_js), default scriptName', () {
      final skill = parseSkillMd(_fixture('calculate-hash'));

      expect(skill.name, 'calculate-hash');
      expect(skill.description, 'Calculate the hash of a given text.');
      expect(skill.type, SkillType.js);
      expect(skill.scriptName, 'index.html');
      // Body (instructions) is everything after the frontmatter.
      expect(skill.instructions, contains('run_js'));
      expect(skill.instructions, startsWith('# Calculate hash'));
      // No metadata block → empty defaults.
      expect(skill.metadata.isEmpty, isTrue);
      expect(skill.requireSecret, isFalse);
    });

    test('interactive-map → js (run_js)', () {
      final skill = parseSkillMd(_fixture('interactive-map'));

      expect(skill.name, 'interactive-map');
      expect(
        skill.description,
        'Show an interactive map view for the given location.',
      );
      expect(skill.type, SkillType.js);
      expect(skill.instructions, contains('run_js'));
    });

    test('send-email → intent (run_intent)', () {
      final skill = parseSkillMd(_fixture('send-email'));

      expect(skill.name, 'send-email');
      expect(skill.description, 'Send an email.');
      expect(skill.type, SkillType.intent);
      expect(skill.instructions, contains('run_intent'));
      expect(skill.instructions, contains('extra_email'));
    });

    test('kitchen-adventure → textOnly (no tool mention)', () {
      final skill = parseSkillMd(_fixture('kitchen-adventure'));

      expect(skill.name, 'kitchen-adventure');
      expect(skill.type, SkillType.textOnly);
      // Body contains a markdown horizontal rule ('---') that the parser must
      // preserve rather than treat as a frontmatter fence.
      expect(skill.instructions, contains('Head Chef (DM)'));
      expect(skill.instructions, contains('---'));
      expect(skill.instructions, contains('What do you do?'));
    });
  });

  group('parseSkillMd — type inference', () {
    Skill parse(String body) =>
        parseSkillMd('---\nname: t\ndescription: d\n---\n$body');

    test('run_js → js', () {
      expect(parse('Call the `run_js` tool.').type, SkillType.js);
    });

    test('run_intent → intent', () {
      expect(parse('Call the `run_intent` tool.').type, SkillType.intent);
    });

    test('run_mcp → mcp', () {
      expect(parse('Call the `run_mcp` tool.').type, SkillType.mcp);
    });

    test('no tool → textOnly', () {
      expect(parse('Just be a friendly persona.').type, SkillType.textOnly);
    });

    test('inferSkillType is case-insensitive', () {
      expect(inferSkillType('RUN_JS now'), SkillType.js);
    });
  });

  group('parseSkillMd — metadata', () {
    test('full metadata block parsed (kebab-case keys)', () {
      const md = '''
---
name: weather
description: Get the weather.
metadata:
  homepage: https://example.com/weather
  require-secret: true
  require-secret-description: Get an API key from example.com.
---
# Weather
Call the `run_mcp` tool.
''';
      final skill = parseSkillMd(md);

      expect(skill.type, SkillType.mcp);
      expect(skill.metadata.homepage, 'https://example.com/weather');
      expect(skill.metadata.requireSecret, isTrue);
      expect(skill.requireSecret, isTrue);
      expect(
        skill.metadata.secretDescription,
        'Get an API key from example.com.',
      );
      expect(skill.metadata.isEmpty, isFalse);
    });

    test('require-secret: false parsed as false', () {
      const md = '''
---
name: x
description: d
metadata:
  require-secret: false
---
body
''';
      expect(parseSkillMd(md).metadata.requireSecret, isFalse);
    });

    test('missing optional fields default cleanly', () {
      const md = '''
---
name: minimal
description: A minimal skill.
---
Be helpful.
''';
      final skill = parseSkillMd(md);

      expect(skill.metadata.homepage, isNull);
      expect(skill.metadata.requireSecret, isFalse);
      expect(skill.metadata.secretDescription, isNull);
      expect(skill.metadata.isEmpty, isTrue);
      expect(skill.scriptName, 'index.html');
    });

    test('partial metadata (homepage only) leaves others default', () {
      const md = '''
---
name: x
description: d
metadata:
  homepage: https://h.example
---
body
''';
      final skill = parseSkillMd(md);

      expect(skill.metadata.homepage, 'https://h.example');
      expect(skill.metadata.requireSecret, isFalse);
      expect(skill.metadata.secretDescription, isNull);
    });
  });

  group('parseSkillMd — scriptName inference', () {
    test('explicit scriptName extracted', () {
      const md = '''
---
name: x
description: d
---
Call `run_js` with scriptName: "query.html" and data {}.
''';
      expect(parseSkillMd(md).scriptName, 'query.html');
    });

    test('"script name: index.html" phrasing extracted', () {
      const md = '''
---
name: x
description: d
---
Call the `run_js` tool with script name: `index.html`.
''';
      expect(parseSkillMd(md).scriptName, 'index.html');
    });
  });

  group('parseSkillMd — errors', () {
    test('no frontmatter throws', () {
      expect(
        () => parseSkillMd('# Just markdown, no frontmatter'),
        throwsA(isA<SkillMdParseException>()),
      );
    });

    test('missing name throws', () {
      const md = '---\ndescription: d\n---\nbody';
      expect(() => parseSkillMd(md), throwsA(isA<SkillMdParseException>()));
    });

    test('missing description throws', () {
      const md = '---\nname: x\n---\nbody';
      expect(() => parseSkillMd(md), throwsA(isA<SkillMdParseException>()));
    });

    test('error message lists the missing field', () {
      const md = '---\nname: x\n---\nbody';
      try {
        parseSkillMd(md);
        fail('expected SkillMdParseException');
      } on SkillMdParseException catch (e) {
        expect(e.errors.join(' '), contains('description'));
      }
    });
  });
}
