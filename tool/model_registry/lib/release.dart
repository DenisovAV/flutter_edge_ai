// What a release of a package needs from the registry: its critical cells
// verified (release_critical.yaml), and a published snapshot of the frozen
// fields it ships (published/<package>/<version>.json), which `check` holds
// every later registry change to.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'check.dart';
import 'site.dart';

typedef CriticalCell = ({
  String package,
  String what,
  String variant,
  String host,
  String backend,
});

/// release_critical.yaml, one cell per variant × host × backend.
List<CriticalCell> readCritical(Directory registryDir, List<Problem> problems) {
  const name = 'release_critical.yaml';
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
  if (doc is! YamlMap) {
    problems.add(Problem(name, '-', 'a map of package to its cells'));
    return const [];
  }
  final out = <CriticalCell>[];
  for (final MapEntry(key: package, value: groups) in doc.entries) {
    if (groups is! YamlList) {
      problems.add(Problem(name, '$package', 'a list of cell groups'));
      continue;
    }
    for (final (i, g) in groups.indexed) {
      if (g case {
        'what': final String what,
        'variants': final YamlList variants,
        'hosts': final YamlList hosts,
        'backends': final YamlList backends,
      }) {
        for (final v in variants) {
          for (final h in hosts) {
            for (final b in backends) {
              out.add((
                package: '$package',
                what: what,
                variant: '$v',
                host: '$h',
                backend: '$b',
              ));
            }
          }
        }
      } else {
        problems.add(
          Problem(
            name,
            '$package[$i]',
            'needs what, variants, hosts, backends',
          ),
        );
      }
    }
  }
  return out;
}

/// Problems with the critical cells: a variant that does not exist, belongs
/// to another package or is withheld, and a cell its package does not run.
void checkCritical(
  SiteInputs inputs,
  List<Entry> entries,
  List<CriticalCell> critical,
  List<Problem> problems,
) {
  final variants = variantsById(entries);
  for (final c in critical) {
    void error(String m) => problems.add(
      Problem('release_critical.yaml', '${c.package} ${c.variant}', m),
    );
    final found = variants[c.variant];
    if (found == null) {
      error('no variant "${c.variant}"');
      continue;
    }
    final (entry, variant) = found;
    if (entry.data['package'] != c.package) {
      error('"${c.variant}" belongs to ${entry.data['package']}');
      continue;
    }
    if (variant['withhold'] != null) {
      error('"${c.variant}" is withheld from the catalog');
      continue;
    }
    final runs = inputs.snapshots[c.package]?[c.variant] ?? const {};
    if (!(runs[c.host] ?? const []).contains(c.backend)) {
      error('the package does not run it on ${c.host} ${c.backend}');
    }
  }
}

/// The critical cells of [package] that are not verified, with their status.
List<(CriticalCell, String)> unverified(
  SiteInputs inputs,
  List<Entry> entries,
  List<CriticalCell> critical,
  String package,
) {
  final all = cells(inputs, entries);
  return [
    for (final c in critical)
      if (c.package == package)
        if (all[c.variant]?[c.host]?[c.backend]?.status case final s
            when s != 'verified')
          (c, s ?? 'n/a'),
  ];
}

/// The frozen fields [package] ships at [version]: every variant its catalog
/// offers.
Map<String, Object?> freezeSnapshot(
  List<Entry> entries,
  String package,
  String version,
) => {
  'package': package,
  'version': version,
  'variants': {
    for (final e in entries)
      if (e.data['package'] == package)
        for (final v in (e.data['variants'] as List? ?? const []))
          if (v case final Map<String, Object?> variant
              when variant['withhold'] == null)
            '${e.id}/${variant['slug']}': frozenValues(variant),
  },
};

/// [freezeSnapshot] as the file `freeze` writes.
String freezeJson(Map<String, Object?> snapshot) =>
    '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n';

/// published/<package>/<version>.json.
File publishedFile(Directory registryDir, String package, String version) =>
    File(p.join(registryDir.path, 'published', package, '$version.json'));

/// The paths under [paths] (relative to the repository at [repoRoot]) that
/// differ from HEAD or are untracked: `release-check` writes its stamp only
/// when none does, so a pass computed on files that are then reverted never
/// stands for the commit the publish runs from. A repository git cannot read
/// is one problem, never an empty answer.
List<String> uncommittedUnder(String repoRoot, List<String> paths) {
  final status = Process.runSync('git', [
    'status',
    '--porcelain',
    '--untracked-files=all',
    '--',
    ...paths,
  ], workingDirectory: repoRoot);
  if (status.exitCode != 0) return ['git status failed: ${status.stderr}'];
  return [
    for (final line in '${status.stdout}'.split('\n'))
      if (line.trim().isNotEmpty) line.substring(3),
  ];
}
