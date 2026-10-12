// Self-test of tool/check_core_surface.sh (R5 §2.3 item 3, §10.1 "Surface"):
// it runs the script over a fixture tree (CHECK_CORE_SURFACE_ROOT) holding
// one violation of each rule, and over a clean tree. A guard that has never
// been seen failing is not known to work.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// From this package's directory, where `tool/test_all.sh` runs the suite.
final _script = File('../../tool/check_core_surface.sh').absolute.path;

void _write(Directory root, String relative, String content) {
  File('${root.path}/$relative')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
}

/// A minimal workspace: core with one private file, and a satellite.
Directory _cleanTree() {
  final root = Directory.systemTemp.createTempSync('core_surface_');
  _write(
    root,
    'packages/flutter_edge_ai/pubspec.yaml',
    'name: flutter_edge_ai\n',
  );
  _write(
    root,
    'packages/flutter_edge_ai/lib/flutter_edge_ai.dart',
    'library;\n',
  );
  _write(root, 'packages/flutter_edge_ai/lib/src/x.dart', 'const x = 1;\n');
  _write(
    root,
    'packages/flutter_edge_ai/example/pubspec.yaml',
    'name: flutter_edge_ai_example\n',
  );
  _write(
    root,
    'packages/flutter_edge_ai/example/lib/main.dart',
    "import 'package:flutter_edge_ai/flutter_edge_ai.dart';\n",
  );
  _write(root, 'packages/sat/pubspec.yaml', 'name: sat\n');
  _write(
    root,
    'packages/sat/lib/sat.dart',
    "import 'package:flutter_edge_ai/engine.dart';\n",
  );
  _write(
    root,
    'packages/sat/test/white_box_test.dart',
    '// ignore: implementation_imports — reads a private constant\n'
        "import 'package:flutter_edge_ai/src/x.dart';\n",
  );
  return root;
}

Future<ProcessResult> _run(Directory root) => Process.run(
  'bash',
  [_script],
  environment: {'CHECK_CORE_SURFACE_ROOT': root.path},
);

void main() {
  test('a clean tree passes and lists the annotated import', () async {
    final root = _cleanTree();
    addTearDown(() => root.deleteSync(recursive: true));

    final result = await _run(root);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('white_box_test.dart'));
    expect(result.stdout, contains('reads a private constant'));
  });

  test('each rule fails on its own violation', () async {
    final root = _cleanTree();
    addTearDown(() => root.deleteSync(recursive: true));
    // (a) a deep path that is neither public nor under src/.
    _write(
      root,
      'packages/sat/lib/a.dart',
      "import 'package:flutter_edge_ai/core/old_path.dart';\n",
    );
    // (b) a src/ import in a test without the annotation.
    _write(
      root,
      'packages/sat/test/b_test.dart',
      "import 'package:flutter_edge_ai/src/x.dart';\n",
    );
    // (c) a src/ import in shipped code, annotated or not.
    _write(
      root,
      'packages/sat/lib/c.dart',
      '// ignore: implementation_imports — no exception for lib/\n'
          "import 'package:flutter_edge_ai/src/x.dart';\n",
    );
    // (c) also an example app's lib/, which ships in the pub archive — the
    // carve-out that once excused one example file is gone.
    _write(
      root,
      'packages/flutter_edge_ai/example/lib/c_example.dart',
      '// ignore: implementation_imports — no exception for example/lib\n'
          "import 'package:flutter_edge_ai/src/x.dart';\n",
    );

    final result = await _run(root);
    final out = '${result.stdout}';
    expect(result.exitCode, 1, reason: out);
    expect(out, contains(RegExp(r'FAIL\s+packages/sat/lib/a\.dart:1\s+\(a\)')));
    expect(
      out,
      contains(RegExp(r'FAIL\s+packages/sat/test/b_test\.dart:1\s+\(b\)')),
    );
    expect(out, contains(RegExp(r'FAIL\s+packages/sat/lib/c\.dart:2\s+\(c\)')));
    expect(
      out,
      contains(
        RegExp(
          r'FAIL\s+packages/flutter_edge_ai/example/lib/c_example\.dart:2\s+\(c\)',
        ),
      ),
    );
    expect(out, contains('4 violation(s)'));
  });

  test('website fences: a src/ import or a deep path fails at its .md line; '
      'other languages are not scanned', () async {
    final root = _cleanTree();
    addTearDown(() => root.deleteSync(recursive: true));
    _write(
      root,
      'website/content/docs/page.md',
      '# Page\n'
          '\n'
          '```dart\n'
          "import 'package:flutter_edge_ai/flutter_edge_ai.dart';\n"
          "import 'package:flutter_edge_ai/src/x.dart';\n"
          '```\n'
          '\n'
          '- In a list:\n'
          '  ```dart\n'
          "  import 'package:flutter_edge_ai/core/old_path.dart';\n"
          '  ```\n'
          '\n'
          '```yaml\n'
          "import 'package:flutter_edge_ai/src/x.dart';\n"
          '```\n',
    );
    // An annotation excuses nothing in a doc.
    _write(
      root,
      'website/content/docs/annotated.md',
      '```dart\n'
          '// ignore: implementation_imports — no exception for docs\n'
          "import 'package:sat/src/y.dart';\n"
          '```\n',
    );
    _write(root, 'packages/sat/lib/src/y.dart', 'const y = 1;\n');
    // Two URIs on one line: reporting the first must not lose the second
    // (the report matches the .md path, which must not move the scan on).
    _write(
      root,
      'website/content/docs/two-uris-on-one-line-of-a-page-with-a-long-name.md',
      '```dart\n'
          "import 'package:flutter_edge_ai/src/x.dart'; "
          "import 'package:flutter_edge_ai/core/old_path.dart';\n"
          '```\n',
    );

    final result = await _run(root);
    final out = '${result.stdout}';
    expect(result.exitCode, 1, reason: out);
    expect(
      out,
      contains(RegExp(r'FAIL\s+website/content/docs/page\.md:5\s+\(d\)')),
    );
    expect(
      out,
      contains(RegExp(r'FAIL\s+website/content/docs/page\.md:10\s+\(a\)')),
    );
    expect(
      out,
      contains(RegExp(r'FAIL\s+website/content/docs/annotated\.md:3\s+\(d\)')),
    );
    expect(
      out,
      contains(
        RegExp(
          r'FAIL\s+website/content/docs/two-uris-on-one-line-of-a-page-with-a-long-name\.md:2\s+\(d\)',
        ),
      ),
    );
    expect(
      out,
      contains(
        RegExp(
          r'FAIL\s+website/content/docs/two-uris-on-one-line-of-a-page-with-a-long-name\.md:2\s+\(a\)',
        ),
      ),
    );
    expect(out, contains('5 violation(s)'));
    expect(out, contains('(4 of them website fences, 0 in codelab texts;'));
  });

  test('codelabs: an app source or a codelab-text fence fails on a src/ '
      'import or a deep path, annotated or not; build output is not '
      'scanned', () async {
    final root = _cleanTree();
    addTearDown(() => root.deleteSync(recursive: true));
    _write(root, 'codelabs/lab/step/pubspec.yaml', 'name: lab_step\n');
    // A codelab app on the public library passes.
    _write(
      root,
      'codelabs/lab/step/lib/main.dart',
      "import 'package:flutter_edge_ai/flutter_edge_ai.dart';\n"
          "import 'package:lab_step/src/own.dart';\n",
    );
    // (d) in lib/.
    _write(
      root,
      'codelabs/lab/step/lib/deep.dart',
      "import 'package:flutter_edge_ai/flutter_edge_ai.dart';\n"
          "import 'package:flutter_edge_ai/src/x.dart';\n",
    );
    // (d) in a test, where the annotation excuses a package's own tests.
    _write(
      root,
      'codelabs/lab/step/test/white_box_test.dart',
      '// ignore: implementation_imports — no exception for codelabs\n'
          "import 'package:sat/src/y.dart';\n",
    );
    _write(root, 'packages/sat/lib/src/y.dart', 'const y = 1;\n');
    // (a) in an integration test.
    _write(
      root,
      'codelabs/lab/step/integration_test/a_test.dart',
      "import 'package:flutter_edge_ai/core/old_path.dart';\n",
    );
    // Build output and the analyzer's cache are generated, never scanned.
    _write(
      root,
      'codelabs/lab/step/build/web/gen.dart',
      "import 'package:flutter_edge_ai/src/x.dart';\n",
    );
    _write(
      root,
      'codelabs/lab/step/.dart_tool/gen.dart',
      "import 'package:flutter_edge_ai/src/x.dart';\n",
    );
    // A codelab text: a dart fence is checked, other languages are not.
    _write(
      root,
      'website/codelabs/lab/index.md',
      '# Lab\n'
          '\n'
          '```dart\n'
          "import 'package:flutter_edge_ai/flutter_edge_ai.dart';\n"
          "import 'package:flutter_edge_ai/src/x.dart';\n"
          '```\n'
          '\n'
          '```text\n'
          "import 'package:flutter_edge_ai/src/x.dart';\n"
          '```\n'
          '\n'
          '```dart\n'
          "import 'package:flutter_edge_ai/core/old_path.dart';\n"
          '```\n',
    );

    final result = await _run(root);
    final out = '${result.stdout}';
    expect(result.exitCode, 1, reason: out);
    expect(
      out,
      contains(
        RegExp(
          r'FAIL\s+codelabs/lab/step/lib/deep\.dart:2\s+\(d\) .* codelab app',
        ),
      ),
    );
    expect(
      out,
      contains(
        RegExp(r'FAIL\s+codelabs/lab/step/test/white_box_test\.dart:2\s+\(d\)'),
      ),
    );
    expect(
      out,
      contains(
        RegExp(
          r'FAIL\s+codelabs/lab/step/integration_test/a_test\.dart:1\s+\(a\)',
        ),
      ),
    );
    expect(
      out,
      contains(RegExp(r'FAIL\s+website/codelabs/lab/index\.md:5\s+\(d\)')),
    );
    expect(
      out,
      contains(RegExp(r'FAIL\s+website/codelabs/lab/index\.md:13\s+\(a\)')),
    );
    expect(out, isNot(contains('build/web/gen.dart')));
    expect(out, isNot(contains('.dart_tool/gen.dart')));
    expect(out, isNot(contains('no exception for codelabs')));
    expect(out, contains('5 violation(s)'));
    // 2 fences (the text one is skipped), both in the codelab text; 4 app
    // sources (build/ and .dart_tool/ excluded).
    expect(
      out,
      contains(
        '(2 of them website fences, 2 in codelab texts; 4 codelab '
        'sources)',
      ),
    );
  });

  test(
    'a website fence and a codelab app on the public libraries pass',
    () async {
      final root = _cleanTree();
      addTearDown(() => root.deleteSync(recursive: true));
      _write(
        root,
        'website/content/docs/page.md',
        "```dart\nimport 'package:flutter_edge_ai/flutter_edge_ai.dart';\n```\n",
      );
      _write(
        root,
        'website/codelabs/lab/index.md',
        "```dart\nimport 'package:flutter_edge_ai/flutter_edge_ai.dart';\n```\n",
      );
      _write(
        root,
        'codelabs/lab/step/lib/main.dart',
        "import 'package:flutter_edge_ai/flutter_edge_ai.dart';\n",
      );

      final result = await _run(root);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(
        result.stdout,
        contains(
          '(2 of them website fences, 1 in codelab texts; 1 codelab '
          'sources)',
        ),
      );
    },
  );

  test(
    'the real repository passes, website fences and codelabs included',
    () async {
      final result = await Process.run('bash', [_script]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final counts = RegExp(
        r'\((\d+) of them website fences, (\d+) in codelab texts; '
        r'(\d+) codelab sources\)',
      ).firstMatch('${result.stdout}');
      expect(counts, isNotNull, reason: '${result.stdout}');
      // A scan that found no fences or no codelab sources has not checked them.
      expect(int.parse(counts!.group(1)!), greaterThan(150));
      expect(int.parse(counts.group(2)!), greaterThan(100));
      expect(int.parse(counts.group(3)!), greaterThan(200));
    },
  );

  test('a tree with nothing to scan is not a pass', () async {
    final root = Directory.systemTemp.createTempSync('core_surface_empty_');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/packages').createSync();

    final result = await _run(root);
    expect(result.exitCode, 1);
  });
}
