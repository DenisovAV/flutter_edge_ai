import 'dart:convert';
import 'dart:io';

import 'package:model_registry/check.dart';
import 'package:model_registry/evidence.dart';
import 'package:model_registry/release.dart';
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
      'slug': 'npu-sm8650',
      'npu': {'vendor': 'qualcomm', 'soc': 'SM8650'},
      'withhold_backends': {
        'npu': {'reason': 'Drops prefill chunks.', 'issue': 'https://x/5'},
        // An NPU build never runs on the GPU: no GPU cell for it.
        'gpu': {'reason': 'Not an NPU problem.', 'issue': 'https://x/6'},
      },
      'file': _file('tiny_sm8650.litertlm'),
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
    'tiny/npu-sm8650': {
      'android_arm64': <String>[],
      'macos_arm64': <String>[],
      'linux_arm64': <String>[],
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
  List<Map<String, Object?>> evidence = const [],
  bool linuxArm64Archive = true,
  bool hook = true,
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
  write(
    'packages/flutter_edge_ai_litertlm/pubspec.yaml',
    'name: flutter_edge_ai_litertlm\nversion: 1.16.1\n',
  );
  if (hook)
    write(
      'packages/flutter_edge_ai_litertlm/hook/build.dart',
      "  checksums: {\n"
          "    'litertlm-macos_arm64.tar.gz':\n        '$_macNative',\n"
          "    'litertlm-android_arm64.tar.gz':\n        '${'b' * 64}',\n"
          "    'litertlm-ios_arm64.tar.gz':\n        '${'c' * 64}',\n"
          "    'litertlm-windows_x86_64.tar.gz':\n        '${'d' * 64}',\n"
          "    'litertlm-linux_x86_64.tar.gz':\n        '${'e' * 64}',\n"
          "${linuxArm64Archive ? "    'litertlm-linux_arm64.tar.gz':\n        '${'f' * 64}',\n" : ''}"
          '  },\n',
    );
  for (final (i, run) in evidence.indexed) {
    write('model_registry/evidence/run$i.json', jsonEncode(run));
  }
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
  List<Map<String, Object?>> evidence = const [],
}) => _repo(claims, problems, snapshot: snapshot, evidence: evidence).$1;

/// The fixture hook's macOS archive.
final _macNative = 'a' * 64;

/// One evidence file: a macOS run of the fixture's native build and package
/// version, unless told otherwise.
Map<String, Object?> _run({
  String host = 'macos_arm64',
  String? native,
  String version = '1.16.1',
  String date = '2026-10-20',
  int schema = 2,
  Map<String, Object?> cells = const {
    'tiny/generic': {
      'gpu': ['text'],
    },
  },
}) => {
  'schema_version': schema,
  'date': date,
  'host': host,
  'device': 'Test Mac',
  'commit': 'c' * 40,
  'packages': {'flutter_edge_ai_litertlm': version},
  'native': native ?? _macNative,
  'log_sha256': 'd' * 64,
  'log_url': null,
  'cells': cells,
};

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
Map<String, Map<String, Map<String, String>>> _statuses(
  String claims, {
  List<Map<String, Object?>> evidence = const [],
}) {
  final problems = <Problem>[];
  final all = cells(_inputs(claims, problems, evidence: evidence), [_llm()]);
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
  group('inputs that would render a wrong page are problems', () {
    test('a snapshot with no answer for a host of hosts.yaml', () {
      final problems = <Problem>[];
      final backends = {
        for (final MapEntry(:key, :value)
            in (_snapshot['backends_here']! as Map<String, Object?>).entries)
          key: {...(value! as Map<String, Object?>)}..remove('linux_arm64'),
      };
      _repo(
        '[]',
        problems,
        snapshot: {..._snapshot, 'backends_here': backends},
      );
      expect(
        problems.map((x) => '$x'),
        contains(contains('linux_arm64: no answer for this host')),
      );
    });

    test('a registry variant its package snapshot does not answer for', () {
      final problems = <Problem>[];
      final backends = {
        ...(_snapshot['backends_here']! as Map<String, Object?>),
      }..remove('tiny/cpu-only');
      final (inputs, _) = _repo(
        '[]',
        problems,
        snapshot: {..._snapshot, 'backends_here': backends},
      );
      checkClaims(inputs, [_llm()], problems);
      expect(
        problems.map((x) => '$x'),
        contains(contains('tiny/cpu-only: no answer for this variant')),
      );
    });

    test('one variant without an answer for a host', () {
      final problems = <Problem>[];
      final backends = {
        ...(_snapshot['backends_here']! as Map<String, Object?>),
        'tiny/generic': {
          ...((_snapshot['backends_here']! as Map)['tiny/generic']! as Map),
        }..remove('web'),
      };
      _repo(
        '[]',
        problems,
        snapshot: {..._snapshot, 'backends_here': backends},
      );
      expect(
        problems.map((x) => '$x'),
        contains(contains('tiny/generic.web: no answer for this host')),
      );
    });

    test('a hook that is gone', () {
      final problems = <Problem>[];
      _repo('[]', problems, hook: false);
      expect(
        problems.map((x) => '$x'),
        contains(contains('hook/build.dart: -: missing')),
      );
    });

    test('a host whose native archive the hook does not name', () {
      final problems = <Problem>[];
      _repo('[]', problems, linuxArm64Archive: false);
      expect(
        problems.map((x) => '$x'),
        contains(contains('linux_arm64: the native build it runs cannot be')),
      );
    });
  });

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

    test('a withheld build says so wherever it would run', () {
      final s = _statuses('[]');
      expect(s['tiny/old']!.keys, [
        'android_arm64',
        'macos_arm64',
        'linux_arm64',
      ]);
      for (final byBackend in s['tiny/old']!.values) {
        expect(byBackend, {'gpu': 'withheld', 'cpu': 'withheld'});
      }
    });

    test('a withheld web export says so on the web only', () {
      expect(_statuses('[]')['tiny/web-old'], {
        'web': {'gpu': 'withheld'},
      });
    });

    test('an NPU build withheld from its NPU is broken on its vendor\'s hosts '
        'only', () {
      final s = _statuses('[]');
      expect(s['tiny/npu-sm8650'], {
        'android_arm64': {'npu': 'broken'},
        'linux_arm64': {'npu': 'broken'},
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
        '"tiny/old" is withheld from the catalog; its cells say why',
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
      // Without the NPU build that is broken there (a status of its own).
      final llm = _llm();
      final refusedOnly = Entry(llm.file, {
        ...llm.data,
        'variants': [
          for (final v in llm.data['variants']! as List)
            if ((v as Map)['slug'] != 'npu-sm8650') v,
        ],
      });
      final cells = row(
        llmPlatformsBlock(_inputs('[]', problems, snapshot: snapshot), [
          refusedOnly,
        ]),
      );
      expect(cells['Android'], 'GPU&nbsp;⚪ CPU&nbsp;⚪');
    });
  });

  group('evidence', () {
    String macGpu(
      List<Map<String, Object?>> evidence, {
      String claims = '[]',
    }) => _statuses(
      claims,
      evidence: evidence,
    )['tiny/generic']!['macos_arm64']!['gpu']!;

    test('a run on the native build shipped now verifies its cell', () {
      expect(macGpu([_run()]), 'verified');
      expect(macGpu([_run(version: '1.16.0')]), 'verified');
    });

    test('a run on another native build or minor version is stale', () {
      expect(macGpu([_run(native: 'e' * 64)]), 'stale');
      expect(macGpu([_run(version: '1.15.0')]), 'stale');
      expect(
        macGpu([_run(native: 'e' * 64), _run(date: '2026-01-01')]),
        'verified',
      );
    });

    test('a run outranks a documented claim', () {
      expect(macGpu([_run()], claims: _docClaim), 'verified');
    });

    test('a verified cell is the best in the summary', () {
      final problems = <Problem>[];
      final block = llmPlatformsBlock(
        _inputs('[]', problems, evidence: [_run()]),
        [_llm()],
      );
      expect(block, contains('GPU&nbsp;✅'));
    });

    List<String> evidenceProblems(
      List<Map<String, Object?>> evidence, {
      String claims = '[]',
    }) {
      final problems = <Problem>[];
      final inputs = _inputs(claims, problems, evidence: evidence);
      checkEvidence(inputs, [_llm()], problems);
      return [for (final problem in problems) problem.message];
    }

    test('check: the fixture run passes', () {
      expect(evidenceProblems([_run()]), isEmpty);
    });

    test('check: a cell the package does not run', () {
      expect(
        evidenceProblems([
          _run(
            cells: const {
              'tiny/generic': {
                'npu': ['text'],
              },
            },
          ),
        ]),
        ['the package does not run "tiny/generic" on macos_arm64 npu'],
      );
    });

    test('check: a withheld variant, an unknown variant, an unknown host', () {
      expect(
        evidenceProblems([
          _run(
            cells: const {
              'tiny/old': {
                'gpu': ['text'],
              },
              'tiny/nope': {
                'gpu': ['text'],
              },
            },
          ),
          _run(host: 'windows_arm64'),
        ]),
        [
          '"tiny/old" is withheld from the catalog',
          'no variant "tiny/nope"',
          'unknown host "windows_arm64"',
        ],
      );
    });

    test('check: a pass where a claim says broken', () {
      final broken = _docClaim
          .replaceFirst('documented', 'broken')
          .replaceFirst('  source:', '  issue: https://x/5\n  source:');
      // Until it is settled, the site keeps the warning.
      expect(macGpu([_run()], claims: broken), 'broken');
      expect(evidenceProblems([_run()], claims: broken), [
        '"tiny/generic" passed on macos_arm64 gpu, which '
            'documented_claims.yaml says is broken; settle which is right',
      ]);
    });

    test('check: a malformed file', () {
      final run = _run()
        ..remove('commit')
        ..['extra'] = 1;
      expect(evidenceProblems([run]), [
        'unknown key "extra"',
        'commit: required',
      ]);
    });

    test('a log: lines anywhere in it, logcat prefixes, bad lines named', () {
      final errors = <String>[];
      final lines = parseEvidenceLog(
        'noise\n'
        'I/flutter (123): FEA_EVIDENCE v2 {"variant":"a/b","host":"android_arm64",'
        '"backend":"gpu","check":"text"}\n'
        'FEA_EVIDENCE v2 {"variant":"a/b"}\n'
        'FEA_EVIDENCE v2 not json\n'
        'FEA_EVIDENCE_SKIP {"file":"x"}\n',
        (line, m) => errors.add('$line: $m'),
      );
      expect(lines, hasLength(1));
      expect(lines.single.host, 'android_arm64');
      expect(errors, hasLength(2));
      expect(errors.first, startsWith('3: needs variant'));
      expect(errors.last, startsWith('4: not JSON'));
    });

    test('a v1 line is refused: it named the text model\'s backend for the '
        'encoders', () {
      final errors = <String>[];
      final lines = parseEvidenceLog(
        'FEA_EVIDENCE v1 {"variant":"a/b","host":"macos_arm64",'
        '"backend":"gpu","check":"audio"}\n',
        (line, m) => errors.add('$line: $m'),
      );
      expect(lines, isEmpty);
      expect(errors.single, contains('v1 line'));
    });

    test('a schema 1 file counts no vision or audio check', () {
      final problems = <Problem>[];
      final run = EvidenceRun.fromJson(
        'f.json',
        _run(
          schema: 1,
          cells: const {
            'tiny/generic': {
              'cpu': ['text'],
              'gpu': ['audio', 'text', 'vision'],
            },
            'tiny/audio-only': {
              'gpu': ['audio'],
            },
          },
        ),
        (m) => problems.add(Problem('f', '-', m)),
      )!;
      expect(problems, isEmpty);
      expect(run.cells, {
        'tiny/generic': {
          'cpu': ['text'],
          'gpu': ['text'],
        },
      });
      expect(run.toJson()['schema_version'], 1);
      final v2 = EvidenceRun.fromJson(
        'f.json',
        _run(
          cells: const {
            'tiny/generic': {
              'cpu': ['audio'],
            },
          },
        ),
        (m) => problems.add(Problem('f', '-', m)),
      )!;
      expect(v2.cells['tiny/generic'], {
        'cpu': ['audio'],
      });
    });

    test('a run is one host, on a device, with a native build', () {
      EvidenceLine line(String host, {bool simulator = false}) => (
        variant: 'tiny/generic',
        host: host,
        backend: 'gpu',
        check: 'text',
        simulator: simulator,
      );
      String? why(List<EvidenceLine> lines, {String? native = 'n'}) {
        String? error;
        runFromLines(
          lines,
          file: 'f.json',
          date: '2026-10-20',
          device: 'd',
          commit: 'c' * 40,
          packages: const {},
          native: native,
          logSha256: 'd' * 64,
          logUrl: null,
          error: (m) => error = m,
        );
        return error;
      }

      expect(why([]), contains('no "FEA_EVIDENCE v2 " line'));
      expect(
        why([line('macos_arm64'), line('ios_arm64')]),
        contains('one run is one host'),
      );
      expect(why([line('ios_arm64', simulator: true)]), contains('simulator'));
      expect(why([line('macos_arm64')], native: null), contains('no native'));
      expect(why([line('macos_arm64')]), isNull);
    });
  });

  group('release', () {
    List<CriticalCell> critical(String yaml, List<Problem> problems) {
      final dir = Directory.systemTemp.createTempSync('release_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'release_critical.yaml')).writeAsStringSync(yaml);
      return readCritical(dir, problems);
    }

    const yaml = '''
flutter_edge_ai_litertlm:
  - what: the default
    variants: [tiny/generic]
    hosts: [macos_arm64, android_arm64]
    backends: [gpu]
''';

    test('groups expand to cells; a malformed group is named', () {
      final problems = <Problem>[];
      final cells = critical(
        '$yaml  - what: no hosts\n    variants: [tiny/generic]\n',
        problems,
      );
      expect(
        [for (final c in cells) '${c.variant} ${c.host} ${c.backend}'],
        ['tiny/generic macos_arm64 gpu', 'tiny/generic android_arm64 gpu'],
      );
      expect(
        [for (final x in problems) x.message],
        ['needs what, variants, hosts, backends'],
      );
    });

    test('check: another package, a withheld variant, a cell not run', () {
      final problems = <Problem>[];
      final cells = critical('''
flutter_edge_ai_speech:
  - what: wrong package
    variants: [tiny/generic]
    hosts: [macos_arm64]
    backends: [gpu]
flutter_edge_ai_litertlm:
  - what: withheld
    variants: [tiny/old]
    hosts: [macos_arm64]
    backends: [gpu]
  - what: not run
    variants: [tiny/generic]
    hosts: [macos_arm64]
    backends: [npu]
''', problems);
      checkCritical(_inputs('[]', problems), [_llm()], cells, problems);
      expect(
        [for (final x in problems) x.message],
        [
          '"tiny/generic" belongs to flutter_edge_ai_litertlm',
          '"tiny/old" is withheld from the catalog',
          'the package does not run it on macos_arm64 npu',
        ],
      );
    });

    test('a release waits for every critical cell to be verified', () {
      final problems = <Problem>[];
      final cells = critical(yaml, problems);
      String missing(List<Map<String, Object?>> evidence) => [
        for (final (c, status) in unverified(
          _inputs('[]', problems, evidence: evidence),
          [_llm()],
          cells,
          'flutter_edge_ai_litertlm',
        ))
          '${c.host} $status',
      ].join(', ');
      expect(missing([]), 'macos_arm64 untested, android_arm64 untested');
      expect(missing([_run()]), 'android_arm64 untested');
      expect(
        missing([_run(native: 'e' * 64)]),
        'macos_arm64 stale, android_arm64 untested',
      );
      expect(problems, isEmpty);
    });

    test('the frozen fields of what the catalog offers', () {
      final snapshot = freezeSnapshot(
        [_llm()],
        'flutter_edge_ai_litertlm',
        '1.16.1',
      );
      final variants = snapshot['variants']! as Map<String, Object?>;
      expect(variants.keys, isNot(contains('tiny/old')));
      expect(variants.keys, contains('tiny/generic'));
      expect(
        variants['tiny/generic'],
        frozenValues(
          (_llm().data['variants']! as List).first as Map<String, Object?>,
        ),
      );
      expect(
        freezeSnapshot(
          [_llm()],
          'flutter_edge_ai_speech',
          '0.5.10',
        )['variants'],
        isEmpty,
      );
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
