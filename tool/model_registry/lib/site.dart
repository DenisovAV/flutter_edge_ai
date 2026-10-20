// What the website shows: for every variant, on every host and backend, a
// status and how it is known. Written to website/web/models.json (the data)
// and website/content/docs/registry.md (the page).
//
// A cell's status comes from, in order:
// - a release withholding the variant or the backend: broken, with its issue;
// - the package's own answer (model_registry/snapshots/<package>.json, what
//   its catalog test recorded): a backend it does not run there is refused
//   (an NPU build on its vendor's platform, a backend it rules out) or n/a;
// - documented_claims.yaml: documented or broken, with the source;
// - otherwise untested.
// Nothing here is verified: that status comes only from recorded runs.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'check.dart';
import 'evidence.dart';

const backends = ['gpu', 'cpu', 'npu'];

/// Where a vendor's NPUs are: the hosts on which a build for it is refused,
/// rather than n/a, when the package does not run it.
const _vendorHosts = {
  'qualcomm': {'android_arm64', 'linux_arm64'},
  'google-tensor': {'android_arm64'},
  'mediatek': {'android_arm64'},
  'intel': {'windows_x64'},
};

typedef Host = ({String id, String label});

typedef Claim = ({
  String what,
  List<String> variants,
  List<String> hosts,
  List<String> backends,
  String status,
  String source,
  String? issue,
});

/// What is known about one variant on one host and backend.
final class Cell {
  const Cell(
    this.status, {
    this.source,
    this.note,
    this.issue,
    this.refusedBy,
    this.log,
  });

  /// verified, stale, documented, untested, refused or broken.
  final String status;

  /// Where the status comes from: a pull request, a docs line, or a run
  /// under evidence/.
  final String? source;

  /// What is broken, for a broken cell; the device, date and version, for a
  /// verified or stale one.
  final String? note;
  final String? issue;

  /// The package version that does not run it, for a refused cell.
  final String? refusedBy;

  /// The run's published log, for a verified or stale cell.
  final String? log;

  Map<String, Object?> toJson() => {
    'status': status,
    if (source != null) 'source': source,
    if (note != null) 'note': note,
    if (issue != null) 'issue': issue,
    if (refusedBy != null) 'refused_by': refusedBy,
    if (log != null) 'log': log,
  };
}

/// A claim's source: a pull request, or a line of a docs page.
final _prSource = RegExp(r'^PR #(\d+)\b(.*)$');

///
/// A docs line is pinned to a commit, so editing the page later does not
/// move what the claim points at: `website/content/docs/<page>.md@<commit>:`
/// and a line or a range of lines.
final _docSource = RegExp(
  r'^(website/content/docs/[a-z0-9-]+\.md)@([0-9a-f]{40}):(\d+)(?:-(\d+))?$',
);

const _repoUrl = 'https://github.com/DenisovAV/flutter_edge_ai';

/// The site's inputs, read once.
final class SiteInputs {
  SiteInputs._(
    this.repoRoot,
    this.hosts,
    this.claims,
    this.snapshots,
    this.versions,
    this.evidence,
  ) : natives = {
        for (final h in hosts)
          if (nativeKey(repoRoot, h.id, versions) case final key?) h.id: key,
      };

  final String repoRoot;

  final List<Host> hosts;
  final List<Claim> claims;

  /// Package → variant id → host → backends it runs there.
  final Map<String, Map<String, Map<String, List<String>>>> snapshots;

  /// Package → version, from its pubspec: core and the packages with a
  /// snapshot.
  final Map<String, String> versions;

  /// The recorded runs, oldest first.
  final List<EvidenceRun> evidence;

  /// Host → the native build the packages ship for it now ([nativeKey]).
  final Map<String, String> natives;

  static SiteInputs read(Directory registryDir, List<Problem> problems) {
    List<Object?> list(String name) {
      final file = File(p.join(registryDir.path, name));
      if (!file.existsSync()) {
        problems.add(Problem(name, '-', 'missing'));
        return const [];
      }
      final Object? doc;
      try {
        doc = loadYaml(file.readAsStringSync());
      } on YamlException catch (e) {
        problems.add(Problem(name, '-', 'not YAML: ${e.message}'));
        return const [];
      }
      if (doc is! YamlList) {
        problems.add(Problem(name, '-', 'not a list'));
        return const [];
      }
      return [for (final item in doc) _plain(item)];
    }

    final hosts = <Host>[];
    for (final (i, h) in list('hosts.yaml').indexed) {
      if (h case {'id': final String id, 'label': final String label}) {
        if (hosts.any((x) => x.id == id)) {
          problems.add(Problem('hosts.yaml', '[$i]', 'duplicate id "$id"'));
        }
        hosts.add((id: id, label: label));
      } else {
        problems.add(Problem('hosts.yaml', '[$i]', 'needs id and label'));
      }
    }
    final claims = <Claim>[];
    for (final (i, c) in list('documented_claims.yaml').indexed) {
      if (c is! Map<String, Object?>) {
        problems.add(
          Problem('documented_claims.yaml', '[$i]', 'not a mapping'),
        );
        continue;
      }
      List<String> strings(String key) => [
        for (final x in (c[key] as List? ?? const [])) '$x',
      ];
      claims.add((
        what: '${c['what'] ?? ''}',
        variants: strings('variants'),
        hosts: strings('hosts'),
        backends: strings('backends'),
        status: '${c['status'] ?? ''}',
        source: '${c['source'] ?? ''}',
        issue: c['issue'] as String?,
      ));
    }
    final snapshots = <String, Map<String, Map<String, List<String>>>>{};
    final snapshotDir = Directory(p.join(registryDir.path, 'snapshots'));
    if (snapshotDir.existsSync()) {
      for (final file in snapshotDir.listSync().whereType<File>()) {
        if (!file.path.endsWith('.json')) continue;
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        snapshots[json['package']! as String] = {
          for (final MapEntry(key: id, value: hosts)
              in (json['backends_here']! as Map<String, Object?>).entries)
            id: {
              for (final MapEntry(key: host, value: list)
                  in (hosts! as Map<String, Object?>).entries)
                host: (list! as List).cast<String>(),
            },
        };
      }
    }
    final repoRoot = p.dirname(p.absolute(registryDir.path));
    final versions = <String, String>{};
    for (final package in ['flutter_edge_ai', ...snapshots.keys]) {
      final pubspec = File(
        p.join(repoRoot, 'packages', package, 'pubspec.yaml'),
      );
      if (pubspec.existsSync()) {
        final yaml = loadYaml(pubspec.readAsStringSync()) as YamlMap;
        versions[package] = '${yaml['version']}';
      }
    }
    return SiteInputs._(
      repoRoot,
      hosts,
      claims,
      snapshots,
      versions,
      readEvidence(registryDir, problems),
    );
  }

  final _pages = <String, List<String>?>{};

  /// The lines of [path] at [commit]; null when the commit is not in this
  /// checkout's history or does not have the file.
  List<String>? pageAt(String commit, String path) =>
      _pages.putIfAbsent('$commit:$path', () {
        final ancestor = Process.runSync('git', [
          'merge-base',
          '--is-ancestor',
          commit,
          'HEAD',
        ], workingDirectory: repoRoot);
        if (ancestor.exitCode != 0) return null;
        final show = Process.runSync('git', [
          'show',
          '$commit:$path',
        ], workingDirectory: repoRoot);
        if (show.exitCode != 0) return null;
        return const LineSplitter().convert(show.stdout as String);
      });

  /// A page's frontmatter title at [commit].
  String pageTitle(String commit, String path) {
    for (final line in pageAt(commit, path) ?? const <String>[]) {
      if (line.startsWith('title: ')) return line.substring(7).trim();
    }
    return p.basenameWithoutExtension(path);
  }
}

Object? _plain(Object? node) => switch (node) {
  YamlMap m => {for (final e in m.entries) e.key.toString(): _plain(e.value)},
  YamlList l => [for (final v in l) _plain(v)],
  _ => node,
};

/// Every variant id with its entry and variant, in registry order.
Map<String, (Entry, Map<String, Object?>)> variantsById(List<Entry> entries) =>
    {
      for (final e in entries)
        for (final v in (e.data['variants'] as List? ?? const []))
          if (v case final Map<String, Object?> variant)
            '${e.id}/${variant['slug']}': (e, variant),
    };

/// Problems with the claims: unknown variants, hosts or backends, a missing
/// source or issue, and a claim on a cell the package does not run.
void checkClaims(
  SiteInputs inputs,
  List<Entry> entries,
  List<Problem> problems,
) {
  final variants = variantsById(entries);
  final hostIds = {for (final h in inputs.hosts) h.id};
  for (final (i, c) in inputs.claims.indexed) {
    void error(String message) => problems.add(
      Problem('documented_claims.yaml', '[$i] ${c.what}', message),
    );
    if (c.status != 'documented' && c.status != 'broken') {
      error('status must be documented or broken');
    }
    if (_docSource.firstMatch(c.source) case final m?) {
      final (path, commit) = (m.group(1)!, m.group(2)!);
      final from = int.parse(m.group(3)!);
      final to = int.parse(m.group(4) ?? m.group(3)!);
      final lines = inputs.pageAt(commit, path);
      if (lines == null) {
        error('$path is not at $commit in this checkout\'s history');
      } else if (from > to) {
        error('the range $from-$to runs backwards');
      } else if (to > lines.length) {
        error('$path has ${lines.length} lines at $commit');
      }
    } else if (!_prSource.hasMatch(c.source)) {
      error(
        'the source is "PR #<n> ..." or '
        '"website/content/docs/<page>.md@<commit>:<line>[-<line>]"; quote it, '
        'since " #" starts a YAML comment',
      );
    }
    if (c.status == 'broken' &&
        (c.issue == null || !c.issue!.startsWith('https://'))) {
      error('a broken claim links its issue');
    }
    for (final h in c.hosts) {
      if (!hostIds.contains(h)) error('unknown host "$h"');
    }
    for (final b in c.backends) {
      if (!backends.contains(b)) error('unknown backend "$b"');
    }
    for (final id in c.variants) {
      final found = variants[id];
      if (found == null) {
        error('no variant "$id"');
        continue;
      }
      final (entry, variant) = found;
      if (variant['withhold'] != null) {
        error('"$id" is withheld from the catalog; its cells say why');
        continue;
      }
      final runs = inputs.snapshots['${entry.data['package']}']?[id];
      if (runs == null) {
        error('"$id" is not in the package snapshot; run the catalog test');
        continue;
      }
      for (final h in c.hosts.where(hostIds.contains)) {
        for (final b in c.backends.where(backends.contains)) {
          if (!(runs[h] ?? const []).contains(b)) {
            error('the package does not run "$id" on $h $b');
          }
        }
      }
    }
  }
}

/// The status of every cell of every variant: variant id → host → backend.
Map<String, Map<String, Map<String, Cell>>> cells(
  SiteInputs inputs,
  List<Entry> entries,
) {
  final claimed = <(String, String, String), Claim>{};
  for (final c in inputs.claims) {
    for (final v in c.variants) {
      for (final h in c.hosts) {
        for (final b in c.backends) {
          claimed[(v, h, b)] = c;
        }
      }
    }
  }
  final out = <String, Map<String, Map<String, Cell>>>{};
  for (final MapEntry(key: id, value: (entry, v)) in variantsById(
    entries,
  ).entries) {
    final package = '${entry.data['package']}';
    final refusedBy = '$package ${inputs.versions[package] ?? ''}'.trim();
    final runs = inputs.snapshots[package]?[id] ?? const {};
    final withhold = v['withhold'] as Map<String, Object?>?;
    final withheldBackends =
        (v['withhold_backends'] as Map<String, Object?>?) ?? const {};
    final npu = v['npu'] as Map<String, Object?>?;
    final web = v['web_bundle'] == true;
    final natural = npu == null ? null : _vendorHosts[npu['vendor']];
    final row = <String, Map<String, Cell>>{};
    for (final host in inputs.hosts) {
      final h = host.id;
      final hostCells = <String, Cell>{};
      for (final b in backends) {
        Cell? cell;
        if (withhold != null) {
          // Withheld: every cell the build would run on says why.
          final wouldRun = npu != null
              ? b == 'npu' && (natural?.contains(h) ?? false)
              : web
              ? h == 'web' && b == 'gpu'
              : h != 'web' && b != 'npu';
          if (wouldRun) {
            cell = Cell(
              'withheld',
              note: '${withhold['reason']}',
              issue: withhold['issue'] as String?,
            );
          }
        } else if ((runs[h] ?? const []).contains(b)) {
          final claim = claimed[(id, h, b)];
          cell = claim?.status == 'broken'
              ? Cell(
                  'broken',
                  source: claim!.source,
                  note: claim.what,
                  issue: claim.issue,
                )
              : _proven(inputs, id, package, h, b) ??
                    (claim == null
                        ? const Cell('untested')
                        : Cell(claim.status, source: claim.source));
        } else if (withheldBackends[b] case final Map<String, Object?> w
            when h != 'web') {
          cell = Cell(
            'broken',
            note: '${w['reason']}',
            issue: w['issue'] as String?,
          );
        } else if (npu != null) {
          if (b == 'npu' && (natural?.contains(h) ?? false)) {
            cell = Cell('refused', refusedBy: refusedBy);
          }
        } else if (!web && h != 'web' && b != 'npu') {
          cell = Cell('refused', refusedBy: refusedBy);
        }
        if (cell != null) hostCells[b] = cell;
      }
      if (hostCells.isNotEmpty) row[h] = hostCells;
    }
    out[id] = row;
  }
  return out;
}

/// The cell's status from recorded runs: verified when a run passed on the
/// native build the packages ship for [host] now and the variant's package is
/// on the same minor version, stale when every such run predates that. Null
/// when nothing was recorded.
Cell? _proven(
  SiteInputs inputs,
  String id,
  String package,
  String host,
  String backend,
) {
  final passed = [
    for (final run in inputs.evidence)
      if (run.host == host && (run.cells[id]?.containsKey(backend) ?? false))
        run,
  ]..sort((a, b) => b.date.compareTo(a.date));
  if (passed.isEmpty) return null;
  String? minor(String? v) => v?.split('.').take(2).join('.');
  bool current(EvidenceRun run) =>
      run.native == inputs.natives[host] &&
      minor(run.packages[package]) == minor(inputs.versions[package]);
  final run = passed.firstWhere(current, orElse: () => passed.first);
  return Cell(
    current(run) ? 'verified' : 'stale',
    source: 'evidence/${run.file}',
    note: '${run.device}, ${run.date}, $package ${run.packages[package]}',
    log: run.logUrl,
  );
}

/// Problems with the recorded runs: an unknown host, a variant that does not
/// exist or is withheld, a cell the package's snapshot does not run, or a
/// cell a broken claim says fails.
///
/// [runs] defaults to the recorded ones; `registry.dart evidence` passes the
/// run it is about to write.
void checkEvidence(
  SiteInputs inputs,
  List<Entry> entries,
  List<Problem> problems, {
  List<EvidenceRun>? runs,
}) {
  final variants = variantsById(entries);
  final hostIds = {for (final h in inputs.hosts) h.id};
  final broken = {
    for (final c in inputs.claims)
      if (c.status == 'broken')
        for (final v in c.variants)
          for (final h in c.hosts)
            for (final b in c.backends) (v, h, b),
  };
  for (final run in runs ?? inputs.evidence) {
    _checkRun(inputs, variants, hostIds, broken, run, problems);
  }
}

/// [checkEvidence] for one run.
void _checkRun(
  SiteInputs inputs,
  Map<String, (Entry, Map<String, Object?>)> variants,
  Set<String> hostIds,
  Set<(String, String, String)> broken,
  EvidenceRun run,
  List<Problem> problems,
) {
  void error(String m) => problems.add(Problem('evidence/${run.file}', '-', m));
  if (!hostIds.contains(run.host)) {
    error('unknown host "${run.host}"');
    return;
  }
  for (final MapEntry(key: id, value: byBackend) in run.cells.entries) {
    final found = variants[id];
    if (found == null) {
      error('no variant "$id"');
      continue;
    }
    final (entry, variant) = found;
    if (variant['withhold'] != null) {
      error('"$id" is withheld from the catalog');
      continue;
    }
    final runs = inputs.snapshots['${entry.data['package']}']?[id] ?? const {};
    for (final b in byBackend.keys) {
      if (!(runs[run.host] ?? const []).contains(b)) {
        error('the package does not run "$id" on ${run.host} $b');
      } else if (broken.contains((id, run.host, b))) {
        error(
          '"$id" passed on ${run.host} $b, which documented_claims.yaml '
          'says is broken; settle which is right',
        );
      }
    }
  }
}

/// website/web/models.json.
String modelsJson(SiteInputs inputs, List<Entry> entries) {
  final all = cells(inputs, entries);
  Map<String, Object?> artifact(Map<String, Object?> a) => {
    'repo': a['repo'],
    'revision': a['revision'],
    'path': a['path'],
    'sha256': a['sha256'],
    'size': a['size'],
    'url': _url(a),
    if (a['gated'] != null) 'gated': a['gated'],
  };
  final json = {
    'schema_version': 1,
    'packages': {
      for (final MapEntry(:key, :value) in inputs.versions.entries) key: value,
    },
    'hosts': [
      for (final h in inputs.hosts) {'id': h.id, 'label': h.label},
    ],
    'statuses': _legend.map((k, v) => MapEntry(k, v.$2)),
    'models': [
      for (final e in entries)
        {
          'id': e.id,
          'kind': e.data['kind'],
          'package': e.data['package'],
          'display_name': e.data['display_name'],
          'family': e.data['family'],
          'arch_class': e.data['arch_class'],
          'license': e.data['license'],
          'license_url': e.data['license_url'],
          'variants': [
            for (final v
                in (e.data['variants']! as List).cast<Map<String, Object?>>())
              {
                'id': '${e.id}/${v['slug']}',
                'slug': v['slug'],
                if (v['file'] case final Map<String, Object?> f)
                  'file': artifact(f),
                if (v['tokenizer'] case final Map<String, Object?> t)
                  'tokenizer': artifact(t),
                if (v['files'] case final List files)
                  'files': [
                    for (final f in files.cast<Map<String, Object?>>())
                      artifact(f),
                  ],
                if (v['npu'] != null) 'npu': v['npu'],
                if (v['web_bundle'] == true) 'web_bundle': true,
                if (v['fixed_max_tokens'] != null)
                  'fixed_max_tokens': v['fixed_max_tokens'],
                'cells': {
                  for (final MapEntry(key: h, value: byBackend)
                      in all['${e.id}/${v['slug']}']!.entries)
                    h: {
                      for (final MapEntry(key: b, value: c)
                          in byBackend.entries)
                        b: c.toJson(),
                    },
                },
              },
          ],
        },
    ],
  };
  return '${const JsonEncoder.withIndent(' ').convert(json)}\n';
}

String _url(Map<String, Object?> a) =>
    'https://huggingface.co/${a['repo']}/resolve/${a['revision']}/'
    '${'${a['path']}'.split('/').map(Uri.encodeComponent).join('/')}';

/// Status → (mark, meaning).
const _legend = {
  'verified': (
    '✅',
    'Passed on that host and backend with the native build the packages ship now',
  ),
  'stale': (
    '🕓',
    'Passed there on an earlier native build; not run since it changed',
  ),
  'documented': (
    '📝',
    'Documented as working; not yet re-run with a recorded log',
  ),
  'untested': ('⚪', 'The package runs it there; nobody has recorded a run'),
  'refused': ('⛔', 'This version of the package does not run it there'),
  'withheld': ('⏸️', 'Left out of the catalog; the note says why'),
  'broken': ('❌', 'Known not to work there; see the issue'),
};

const _kindTitles = {
  'llm': 'Language models',
  'embedder': 'Embedding models',
  'stt': 'Speech to text',
  'tts': 'Text to speech',
};

/// website/content/docs/registry.md.
String registryPage(SiteInputs inputs, List<Entry> entries) {
  final all = cells(inputs, entries);
  final out = StringBuffer()
    ..writeln('---')
    ..writeln('title: Model Registry')
    ..writeln(
      'description: Every LiteRT model build flutter_edge_ai runs, pinned to '
      'its Hugging Face commit, with where it runs and how that is known.',
    )
    ..writeln('meta:')
    ..writeln('  - property: og:image')
    ..writeln('    content: https://flutteredge.ai/images/og-image.png')
    ..writeln('---')
    ..writeln()
    ..writeln(
      '<!-- GENERATED by tool/model_registry from model_registry/. Do not '
      'edit: change the registry and generate again. -->',
    )
    ..writeln()
    ..writeln(
      'Every LiteRT build the packages run, each pinned to a Hugging Face '
      'commit, and for every platform and backend what is known about it. '
      'The same data is in [models.json](/models.json). Install a build by '
      'name, with no URL to copy:',
    )
    ..writeln()
    ..writeln('```dart')
    ..writeln(
      'await FlutterEdgeAi.installFromCatalog(LiteRtLmModels.gemma4E2bIt.generic)'
      '.install();',
    )
    ..writeln('```')
    ..writeln()
    ..writeln('| Mark | Meaning |')
    ..writeln('|---|---|');
  for (final MapEntry(key: status, value: (mark, meaning)) in _legend.entries) {
    out.writeln('| $mark $status | $meaning |');
  }
  out
    ..writeln()
    ..writeln(
      'A blank cell is a combination that does not exist: a build compiled '
      'for one NPU on another platform, a web export on a phone, or a native '
      'build on the web. Package '
      'versions: ${inputs.versions.entries.map((e) => '`${e.key}` ${e.value}').join(', ')}.',
    )
    ..writeln();
  for (final kind in _kindTitles.keys) {
    final models = [
      for (final e in entries)
        if (e.data['kind'] == kind) e,
    ];
    if (models.isEmpty) continue;
    out
      ..writeln('## ${_kindTitles[kind]}')
      ..writeln();
    for (final e in models) {
      _modelSection(out, inputs, e, all);
    }
  }
  return out.toString();
}

void _modelSection(
  StringBuffer out,
  SiteInputs inputs,
  Entry e,
  Map<String, Map<String, Map<String, Cell>>> all,
) {
  final variants = (e.data['variants']! as List).cast<Map<String, Object?>>();
  final first =
      (variants.first['file'] ?? (variants.first['files']! as List).first)
          as Map<String, Object?>;
  out
    // An anchor by registry id, which the models page links to; the
    // heading's own id is the site's slug of the display name.
    ..writeln('<a id="${e.id}"></a>')
    ..writeln()
    ..writeln('### ${e.data['display_name']}')
    ..writeln()
    ..writeln(
      '`${e.id}` · ${e.data['license']} · '
      '[Hugging Face](https://huggingface.co/${first['repo']})',
    )
    ..writeln()
    ..writeln('| Build | ${inputs.hosts.map((h) => h.label).join(' | ')} |')
    ..writeln('|---|${inputs.hosts.map((_) => ':---:').join('|')}|');
  final notes = <String>{};
  for (final v in variants) {
    final id = '${e.id}/${v['slug']}';
    final files = v['files'] != null
        ? (v['files']! as List).cast<Map<String, Object?>>()
        : [v['file']! as Map<String, Object?>];
    final size = files.fold(0, (s, f) => s + (f['size']! as int));
    final f = files.first;
    final link = v['files'] != null
        ? 'https://huggingface.co/${f['repo']}/tree/${f['revision']}'
        : 'https://huggingface.co/${f['repo']}/blob/${f['revision']}/${f['path']}';
    // The slug names the NPU (npu-sm8750); the cell gives the size and, for
    // a build compiled for one, the KV-cache length that bounds maxTokens.
    final context = v['fixed_max_tokens'] == null
        ? ''
        : ' · context&nbsp;${v['fixed_max_tokens']}';
    final row = StringBuffer(
      '| [${v['slug']}]($link)<br>'
      '${_size(size).replaceAll(' ', '&nbsp;')}$context |',
    );
    for (final host in inputs.hosts) {
      final byBackend = all[id]![host.id] ?? const {};
      final parts = [
        for (final b in backends)
          if (byBackend[b] case final c?)
            '${b.toUpperCase()}&nbsp;${_legend[c.status]!.$1}',
      ];
      row.write(' ${parts.join(' ')} |');
      for (final c in byBackend.values) {
        if (c.status == 'verified' || c.status == 'stale') {
          final log = c.log == null ? '' : ' ([log](${c.log}))';
          notes.add(
            '${c.status == 'verified' ? 'Verified' : 'Stale'} on '
            '${host.label}: ${c.note}$log.',
          );
        }
        if (c.status == 'documented' && c.source != null) {
          notes.add('Documented: ${_source(inputs, c.source!)}.');
        }
        if (c.status == 'withheld') {
          final note = _markdownText(c.note!.replaceFirst(RegExp(r'\.$'), ''));
          notes.add('Withheld: $note. [Issue](${c.issue}).');
        }
        if (c.status == 'broken') {
          final from = c.source == null
              ? ''
              : ' (${_source(inputs, c.source!)})';
          final note = _markdownText(c.note!.replaceFirst(RegExp(r'\.$'), ''));
          notes.add('Broken: $note$from. [Issue](${c.issue}).');
        }
      }
    }
    out.writeln(row);
  }
  out.writeln();
  for (final note in notes) {
    out.writeln('- $note');
  }
  if (notes.isNotEmpty) out.writeln();
}

/// A claim's source as a link where it is a pull request or a docs page.
String _source(SiteInputs inputs, String source) {
  if (_prSource.firstMatch(source) case final pr?) {
    final n = pr.group(1);
    return '[PR #$n]($_repoUrl/pull/$n)${pr.group(2)}';
  }
  if (_docSource.firstMatch(source) case final doc?) {
    final (path, commit) = (doc.group(1)!, doc.group(2)!);
    final lines = doc.group(4) == null
        ? 'L${doc.group(3)}'
        : 'L${doc.group(3)}-L${doc.group(4)}';
    return 'the ${inputs.pageTitle(commit, path)} page '
        '([at ${commit.substring(0, 7)}]($_repoUrl/blob/$commit/$path#$lines))';
  }
  return source;
}

/// [text] with the characters markdown would read as HTML escaped, so a
/// token like `<pad>` is shown rather than swallowed as a tag.
String _markdownText(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _size(int bytes) => bytes >= 1000 * 1000 * 1000
    ? '${(bytes / 1e9).toStringAsFixed(2)} GB'
    : '${(bytes / 1e6).round()} MB';

/// The marker pair that fences a generated block inside a hand-written page.
({String begin, String end}) _markers(String name) =>
    (begin: '<!-- registry:$name -->', end: '<!-- /registry:$name -->');

/// The pages that carry a generated block, and the block's name.
const _blocks = {'website/content/docs/models.md': 'llm-platforms'};

/// [doc] with the block [name] replaced by [block]; null when [doc] does not
/// have the markers, once each and in order.
String? spliceBlock(String doc, String name, String block) {
  final (:begin, :end) = _markers(name);
  final at = doc.indexOf(begin);
  final to = doc.indexOf(end);
  if (at < 0 ||
      to < at ||
      doc.indexOf(begin, at + 1) >= 0 ||
      doc.indexOf(end, to + 1) >= 0) {
    return null;
  }
  return '${doc.substring(0, at + begin.length)}\n\n$block\n'
      '${doc.substring(to)}';
}

/// Problems with the pages that carry a generated block: a missing page or
/// missing markers.
void checkBlocks(SiteInputs inputs, List<Problem> problems) {
  for (final MapEntry(key: path, value: name) in _blocks.entries) {
    final file = File(p.join(inputs.repoRoot, path));
    if (!file.existsSync()) {
      problems.add(Problem(path, '-', 'missing; it carries the $name block'));
    } else if (spliceBlock(file.readAsStringSync(), name, '') == null) {
      final (:begin, :end) = _markers(name);
      problems.add(
        Problem(path, '-', 'needs one "$begin" and, after it, one "$end"'),
      );
    }
  }
}

/// The best status first: a summary cell shows the best a model has.
const _rank = [
  'verified',
  'stale',
  'documented',
  'untested',
  'withheld',
  'broken',
  'refused',
];

/// The models page's platform table: one row per language model, and per
/// host the best status each backend has over the model's builds. A backend
/// that is only refused there is left out.
String llmPlatformsBlock(SiteInputs inputs, List<Entry> entries) {
  final all = cells(inputs, entries);
  final out = StringBuffer()
    ..writeln(
      '<!-- GENERATED by tool/model_registry from model_registry/. Edit the '
      'registry, not this table. -->',
    )
    ..writeln()
    ..writeln(
      '| Model | Size | ${inputs.hosts.map((h) => h.label).join(' | ')} '
      '| HF token |',
    )
    ..writeln('|---|---|${inputs.hosts.map((_) => ':---:').join('|')}|:---:|');
  for (final e in entries) {
    if (e.data['kind'] != 'llm') continue;
    final variants = (e.data['variants']! as List).cast<Map<String, Object?>>();
    final sizes = [
      for (final v in variants)
        if (v['npu'] == null && v['withhold'] == null)
          (v['file']! as Map<String, Object?>)['size']! as int,
    ]..sort();
    final size = sizes.isEmpty
        ? ''
        : sizes.first == sizes.last
        ? _size(sizes.first)
        : '${_size(sizes.first).split(' ').first}–${_size(sizes.last)}';
    final gated = variants.any(
      (v) => (v['file']! as Map<String, Object?>)['gated'] != null,
    );
    final row = StringBuffer(
      '| [${e.data['display_name']}](/docs/registry#${e.id}) '
      '| ${size.replaceAll(' ', '&nbsp;')} |',
    );
    for (final host in inputs.hosts) {
      final best = <String, String>{};
      for (final v in variants) {
        final byBackend = all['${e.id}/${v['slug']}']![host.id] ?? const {};
        for (final MapEntry(key: b, value: c) in byBackend.entries) {
          final was = best[b];
          if (was == null || _rank.indexOf(c.status) < _rank.indexOf(was)) {
            best[b] = c.status;
          }
        }
      }
      final parts = [
        for (final b in backends)
          if (best[b] case final status? when status != 'refused')
            '${b.toUpperCase()}&nbsp;${_legend[status]!.$1}',
      ];
      row.write(' ${parts.join(' ')} |');
    }
    row.write(' ${gated ? 'yes' : 'no'} |');
    out.writeln(row);
  }
  return out.toString().trimRight();
}

/// The website's generated files: the registry page, its data, and the
/// generated blocks of the hand-written pages.
List<({String path, String content})> generateSite(
  SiteInputs inputs,
  List<Entry> entries,
) => [
  (path: 'website/web/models.json', content: modelsJson(inputs, entries)),
  (
    path: 'website/content/docs/registry.md',
    content: registryPage(inputs, entries),
  ),
  for (final MapEntry(key: path, value: name) in _blocks.entries)
    if (File(p.join(inputs.repoRoot, path)) case final file
        when file.existsSync())
      if (spliceBlock(
            file.readAsStringSync(),
            name,
            llmPlatformsBlock(inputs, entries),
          )
          case final content?)
        (path: path, content: content),
];
