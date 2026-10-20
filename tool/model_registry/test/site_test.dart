import 'dart:convert';
import 'dart:io';

import 'package:model_registry/check.dart';
import 'package:model_registry/site.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _hosts = '''
- id: android_arm64
  label: Android
- id: macos_arm64
  label: macOS
- id: linux_arm64
  label: Linux arm64
- id: web
  label: Web
''';

Map<String, Object?> _file(String path) => {
  'repo': 'litert-community/example',
  'revision': '0123456789abcdef0123456789abcdef01234567',
  'path': path,
  'sha256': 'a' * 64,
  'size': 1000000,
};

/// One LLM: a generic build, a web export, a Qualcomm build, a MediaTek
/// build, a build withheld from the release, a withheld web export, and a build
/// whose GPU is withheld.
Entry _llm() => Entry('models/tiny.yaml', {
  'id': 'tiny',
  'kind': 'llm',
  'package': 'flutter_edge_ai_litertlm',
  'display_name': 'Tiny',
  'license': 'apache-2.0',
  'variants': [
    {'slug': 'generic', 'file': _file('tiny.litertlm')},
    {'slug': 'web', 'web_bundle': true, 'file': _file('tiny-web.litertlm')},
    {
      'slug': 'npu-sm8750',
      'npu': {'vendor': 'qualcomm', 'soc': 'SM8750'},
      'file': _file('tiny_sm8750.litertlm'),
    },
    {
      'slug': 'npu-mt6993',
      'npu': {'vendor': 'mediatek', 'soc': 'mt6993'},
      'file': _file('tiny_mt6993.litertlm'),
    },
    {
      'slug': 'old',
      'withhold': {'reason': 'Fails to load.', 'issue': 'https://x/1'},
      'file': _file('tiny-old.litertlm'),
    },
    {
      'slug': 'web-old',
      'web_bundle': true,
      'withhold': {'reason': 'Fails on WebGPU.', 'issue': 'https://x/4'},
      'file': _file('tiny-web-old.litertlm'),
    },
    {
      'slug': 'cpu-only',
      'withhold_backends': {
        'gpu': {'reason': 'Emits <pad>.', 'issue': 'https://x/2'},
      },
      'file': _file('tiny-cpu.litertlm'),
    },
  ],
});

/// What the package's catalog test records for [_llm]: the generic build on
/// every native host's CPU and GPU, the web export on the web, the Qualcomm
/// build on the NPU, and the MediaTek build nowhere.
const _snapshot = {
  'package': 'flutter_edge_ai_litertlm',
  'backends_here': {
    'tiny/generic': {
      'android_arm64': ['cpu', 'gpu'],
      'macos_arm64': ['cpu', 'gpu'],
      'linux_arm64': ['cpu', 'gpu'],
      'web': <String>[],
    },
    'tiny/web': {
      'android_arm64': <String>[],
      'macos_arm64': <String>[],
      'linux_arm64': <String>[],
      'web': ['gpu'],
    },
    'tiny/npu-sm8750': {
      'android_arm64': ['npu'],
      'macos_arm64': <String>[],
      'linux_arm64': ['npu'],
      'web': <String>[],
    },
    'tiny/npu-mt6993': {
      'android_arm64': <String>[],
      'macos_arm64': <String>[],
      'linux_arm64': <String>[],
      'web': <String>[],
    },
    'tiny/cpu-only': {
      'android_arm64': ['cpu'],
      'macos_arm64': ['cpu'],
      'linux_arm64': ['cpu'],
      'web': <String>[],
    },
  },
};

const _docClaim = '''
- what: Tiny on the GPU
  variants: [tiny/generic]
  hosts: [macos_arm64]
  backends: [gpu]
  status: documented
  source: website/content/docs/models.md@COMMIT:3
''';

/// A git repo in a temp dir: model_registry/ with [claims], and a committed
/// three-line docs page the claims cite at that commit (COMMIT in [claims];
/// SIDE is a commit outside HEAD's history).
/// Returns the inputs and the commit.
(SiteInputs, String) _repo(
  String claims,
  List<Problem> problems, {
  Map<String, Object?> snapshot = _snapshot,
}) {
  final root = Directory.systemTemp.createTempSync('site_test');
  addTearDown(() => root.deleteSync(recursive: true));
  void write(String path, String content) => File(p.join(root.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  String git(List<String> args) {
    final r = Process.runSync('git', [
      '-c',
      'user.name=test',
      '-c',
      'user.email=test@example.com',
      ...args,
    ], workingDirectory: root.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return (r.stdout as String).trim();
  }

  write('website/content/docs/models.md', '---\ntitle: Models\n---\n');
  write('website/content/docs/later.md', '---\ntitle: Later\n---\n');
  git(['init', '-q']);
  git(['add', 'website/content/docs/models.md']);
  git(['commit', '-q', '-m', 'docs']);
  final commit = git(['rev-parse', 'HEAD']);
  // A commit that has the page but is not in HEAD's history, like a branch
  // that was never merged.
  final side = git(['commit-tree', 'HEAD^{tree}', '-p', 'HEAD', '-m', 'side']);
  write('model_registry/hosts.yaml', _hosts);
  write(
    'model_registry/documented_claims.yaml',
    claims.replaceAll('SIDE', side).replaceAll('COMMIT', commit),
  );
  write(
    'model_registry/snapshots/flutter_edge_ai_litertlm.json',
    jsonEncode(snapshot),
  );
  final inputs = SiteInputs.read(
    Directory(p.join(root.path, 'model_registry')),
    problems,
  );
  return (inputs, commit);
}

SiteInputs _inputs(
  String claims,
  List<Problem> problems, {
  Map<String, Object?> snapshot = _snapshot,
}) => _repo(claims, problems, snapshot: snapshot).$1;

/// The claim problems, with the fixture's commit written as COMMIT.
List<String> _claimProblems(String claims) {
  final problems = <Problem>[];
  final (inputs, commit) = _repo(claims, problems);
  checkClaims(inputs, [_llm()], problems);
  return [
    for (final problem in problems)
      problem.message.replaceAll(commit, 'COMMIT'),
  ];
}

/// variant → host → backend → status, n/a cells left out.
Map<String, Map<String, Map<String, String>>> _statuses(String claims) {
  final problems = <Problem>[];
  final all = cells(_inputs(claims, problems), [_llm()]);
  expect(problems, isEmpty);
  return {
    for (final MapEntry(key: id, value: hosts) in all.entries)
      id: {
        for (final MapEntry(key: h, value: byBackend) in hosts.entries)
          h: {
            for (final MapEntry(key: b, value: c) in byBackend.entries)
              b: c.status,
          },
      },
  };
}

void main() {
  group('cells', () {
    test('what the package runs is untested until a claim says more', () {
      final s = _statuses(_docClaim);
      expect(s['tiny/generic']!['macos_arm64'], {
        'gpu': 'documented',
        'cpu': 'untested',
      });
      expect(s['tiny/generic']!['android_arm64'], {
        'gpu': 'untested',
        'cpu': 'untested',
      });
    });

    test('a native build has no web cell, a web export no native one', () {
      final s = _statuses('[]');
      expect(s['tiny/generic']!.keys, isNot(contains('web')));
      expect(s['tiny/web'], {
        'web': {'gpu': 'untested'},
      });
    });

    test('an NPU build lives only on its vendor platforms', () {
      final s = _statuses('[]');
      expect(s['tiny/npu-sm8750'], {
        'android_arm64': {'npu': 'untested'},
        'linux_arm64': {'npu': 'untested'},
      });
    });

    test('an NPU build the package does not run is refused there', () {
      final s = _statuses('[]');
      expect(s['tiny/npu-mt6993'], {
        'android_arm64': {'npu': 'refused'},
      });
    });

    test('a withheld build is broken wherever it would run', () {
      final s = _statuses('[]');
      expect(s['tiny/old']!.keys, [
        'android_arm64',
        'macos_arm64',
        'linux_arm64',
      ]);
      for (final byBackend in s['tiny/old']!.values) {
        expect(byBackend, {'gpu': 'broken', 'cpu': 'broken'});
      }
    });

    test('a withheld web export is broken on the web only', () {
      expect(_statuses('[]')['tiny/web-old'], {
        'web': {'gpu': 'broken'},
      });
    });

    test('a withheld backend is broken, the rest of the build is not', () {
      final s = _statuses('[]');
      expect(s['tiny/cpu-only']!.keys, isNot(contains('web')));
      expect(s['tiny/cpu-only']!['android_arm64'], {
        'gpu': 'broken',
        'cpu': 'untested',
      });
    });

    test('a broken claim carries what is broken and its issue', () {
      final problems = <Problem>[];
      final all = cells(
        _inputs('''
- what: Tiny crashes on the NPU
  variants: [tiny/npu-sm8750]
  hosts: [android_arm64]
  backends: [npu]
  status: broken
  source: "PR #1"
  issue: https://x/3
''', problems),
        [_llm()],
      );
      final cell = all['tiny/npu-sm8750']!['android_arm64']!['npu']!;
      expect(cell.toJson(), {
        'status': 'broken',
        'source': 'PR #1',
        'note': 'Tiny crashes on the NPU',
        'issue': 'https://x/3',
      });
    });
  });

  group('each claim rule fails its own fixture', () {
    final cases = {
      'no variant': (
        _docClaim.replaceFirst('tiny/generic', 'tiny/nope'),
        'no variant "tiny/nope"',
      ),
      'unknown host': (
        _docClaim.replaceFirst('[macos_arm64]', '[ios_arm64]'),
        'unknown host "ios_arm64"',
      ),
      'unknown backend': (
        _docClaim.replaceFirst('[gpu]', '[tpu]'),
        'unknown backend "tpu"',
      ),
      'a cell the package does not run': (
        _docClaim.replaceFirst('[gpu]', '[npu]'),
        'the package does not run "tiny/generic" on macos_arm64 npu',
      ),
      'a withheld variant': (
        _docClaim.replaceFirst('tiny/generic', 'tiny/old'),
        '"tiny/old" is withheld from the release; its cells are broken',
      ),
      'a bad status': (
        _docClaim.replaceFirst('documented', 'verified'),
        'status must be documented or broken',
      ),
      'a source YAML cut at " #"': (
        _docClaim.replaceFirst(
          'website/content/docs/models.md@COMMIT:3',
          'PR #688, device matrix',
        ),
        'the source is "PR #<n> ..." or '
            '"website/content/docs/<page>.md@<commit>:<line>[-<line>]"; quote '
            'it, since " #" starts a YAML comment',
      ),
      'a docs line not pinned to a commit': (
        _docClaim.replaceFirst('models.md@COMMIT:3', 'models.md:3'),
        'the source is "PR #<n> ..." or '
            '"website/content/docs/<page>.md@<commit>:<line>[-<line>]"; quote '
            'it, since " #" starts a YAML comment',
      ),
      'a docs range past the end': (
        _docClaim.replaceFirst('models.md@COMMIT:3', 'models.md@COMMIT:2-4'),
        'website/content/docs/models.md has 3 lines at COMMIT',
      ),
      'a range that runs backwards': (
        _docClaim.replaceFirst('models.md@COMMIT:3', 'models.md@COMMIT:3-2'),
        'the range 3-2 runs backwards',
      ),
      'a page the commit does not have': (
        _docClaim.replaceFirst('models.md@COMMIT', 'later.md@COMMIT'),
        "website/content/docs/later.md is not at COMMIT in this checkout's "
            'history',
      ),
      'a commit outside the history': (
        _docClaim.replaceFirst('COMMIT', 'SIDE'),
        'SIDE',
      ),
      'a commit that does not exist': (
        _docClaim.replaceFirst('COMMIT', 'f' * 40),
        "website/content/docs/models.md is not at ${'f' * 40} in this "
            "checkout's history",
      ),
      'a broken claim without an issue': (
        _docClaim.replaceFirst('documented', 'broken'),
        'a broken claim links its issue',
      ),
    };
    for (final MapEntry(key: name, value: (claims, message)) in cases.entries) {
      if (message == 'SIDE') {
        test(name, () {
          final problems = _claimProblems(claims);
          expect(problems, hasLength(1));
          expect(problems.single, contains("in this checkout's history"));
          expect(problems.single, isNot(contains('COMMIT')));
        });
        continue;
      }
      test(name, () => expect(_claimProblems(claims), [message]));
    }

    test('the fixture itself passes', () {
      expect(_claimProblems(_docClaim), isEmpty);
    });
  });

  group('generated blocks', () {
    const doc =
        'before\n<!-- registry:x -->\nold\n<!-- /registry:x -->\nafter\n';

    test('a block replaces what is between its markers', () {
      expect(
        spliceBlock(doc, 'x', 'new'),
        'before\n<!-- registry:x -->\n\nnew\n<!-- /registry:x -->\nafter\n',
      );
    });

    test('a page without the markers, or with two, is not spliced', () {
      expect(spliceBlock('before\n', 'x', 'new'), isNull);
      expect(spliceBlock('$doc$doc', 'x', 'new'), isNull);
      expect(spliceBlock('<!-- registry:x -->\n$doc', 'x', 'new'), isNull);
      expect(
        spliceBlock('<!-- /registry:x -->\n<!-- registry:x -->\n', 'x', 'new'),
        isNull,
      );
    });

    test('check names a page that lost its markers', () {
      final problems = <Problem>[];
      checkBlocks(_inputs('[]', problems), problems);
      expect(
        [for (final problem in problems) '$problem'],
        [
          'website/content/docs/models.md: -: needs one '
              '"<!-- registry:llm-platforms -->" and, after it, one '
              '"<!-- /registry:llm-platforms -->"',
        ],
      );
    });

    /// The summary row's cells, by host label.
    Map<String, String> row(String block) {
      final lines = block
          .split('\n')
          .where((l) => l.startsWith('| ['))
          .toList();
      expect(lines, hasLength(1));
      final cells = lines.single.split(' | ');
      return {
        for (final (i, h) in ['Android', 'macOS', 'Linux arm64', 'Web'].indexed)
          h: cells[2 + i],
      };
    }

    test('a summary cell shows each backend at its best build', () {
      final problems = <Problem>[];
      final cells = row(
        llmPlatformsBlock(_inputs(_docClaim, problems), [_llm()]),
      );
      // GPU: generic untested beats old and cpu-only broken. NPU: the
      // Qualcomm build untested beats the MediaTek one refused.
      expect(cells['Android'], 'GPU&nbsp;⚪ CPU&nbsp;⚪ NPU&nbsp;⚪');
      expect(cells['macOS'], 'GPU&nbsp;📝 CPU&nbsp;⚪');
      expect(cells['Web'], 'GPU&nbsp;⚪');
    });

    test('a backend refused on every build is left out of the summary', () {
      final problems = <Problem>[];
      final snapshot =
          jsonDecode(jsonEncode(_snapshot)) as Map<String, Object?>;
      ((snapshot['backends_here']! as Map)['tiny/npu-sm8750']!
              as Map)['android_arm64'] =
          <String>[];
      final cells = row(
        llmPlatformsBlock(_inputs('[]', problems, snapshot: snapshot), [
          _llm(),
        ]),
      );
      expect(cells['Android'], 'GPU&nbsp;⚪ CPU&nbsp;⚪');
    });
  });

  test('the repo claims pass', () {
    final registry = Directory(p.join('..', '..', 'model_registry'));
    final result = checkRegistry(registry);
    final problems = <Problem>[];
    checkClaims(SiteInputs.read(registry, problems), result.entries, problems);
    expect([for (final problem in problems) '$problem'], isEmpty);
  });
}
