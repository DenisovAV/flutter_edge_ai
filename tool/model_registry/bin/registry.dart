// The model registry tool. Run from tool/model_registry:
//
//   dart run bin/registry.dart check
//   dart run bin/registry.dart generate
//   dart run bin/registry.dart evidence --device "<device>" <log>...
//   dart run bin/registry.dart live
//   dart run bin/registry.dart freeze <package>
//   dart run bin/registry.dart release-check <package>
//
// `check` validates model_registry/ (the repo root's) and that every
// generated file is what `generate` would write; it exits 1 on any problem.
// `generate` writes the generated files. `evidence` turns the log of an
// integration run into model_registry/evidence/<date>_<host>_<device>.json.
// `live` asks Hugging Face for every pinned file (HF_TOKEN for gated ones)
// and exits 1 when one is missing or differs. `freeze` writes the frozen
// fields a release of <package> ships (published/<package>/<version>.json);
// `release-check` says whether <package> may be published: the registry and
// every generated file are current, the frozen fields are written, and its
// cells in release_critical.yaml are verified.
// See ../../model_registry/README.md.

import 'dart:convert';
import 'dart:io';

import 'package:model_registry/check.dart';
import 'package:model_registry/evidence.dart';
import 'package:model_registry/generate.dart';
import 'package:model_registry/live.dart';
import 'package:model_registry/release.dart';
import 'package:model_registry/site.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final command = args.isEmpty ? null : args.first;
  const commands = {
    'check',
    'generate',
    'evidence',
    'live',
    'freeze',
    'release-check',
  };
  if (!commands.contains(command)) {
    stderr.writeln(
      'usage: dart run bin/registry.dart check|generate|live [--registry <dir>]\n'
      '       dart run bin/registry.dart freeze|release-check <package>\n'
      '       dart run bin/registry.dart evidence --device <device> '
      '[--log-url <url>] [--date <yyyy-mm-dd>] [--allow-dirty] <log>...',
    );
    exit(64);
  }
  String? option(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  // freeze and release-check name a package: without one, the usage, before
  // anything the registry says.
  if ((command == 'freeze' || command == 'release-check') &&
      (args.length < 2 || args[1].startsWith('--'))) {
    stderr.writeln('$command needs a package: $command <package>');
    exit(64);
  }
  final registry = Directory(option('--registry') ?? _defaultRegistry());
  final repoRoot = p.dirname(p.absolute(registry.path));
  final result = checkRegistry(registry);
  final site = SiteInputs.read(registry, result.problems);
  checkClaims(site, result.entries, result.problems);
  checkBlocks(site, result.problems);
  checkEvidence(site, result.entries, result.problems);
  final critical = readCritical(registry, result.problems);
  checkCritical(site, result.entries, critical, result.problems);
  // The release in progress: see releaseGate.
  final gate = releaseGate(
    command!,
    result.problems,
    site.versions,
    package: args.length > 1 && !args[1].startsWith('--') ? args[1] : null,
    everCommitted: (file) => everCommitted(
      repoRoot,
      p.join(p.relative(p.absolute(registry.path), from: repoRoot), file),
    ),
  );
  for (final problem in gate.pending) {
    stdout.writeln(
      'pending until `registry.dart freeze ${problem.awaitsFreeze!.$1}`: '
      '$problem',
    );
  }
  result.problems
    ..clear()
    ..addAll(gate.blocking);
  if (command == 'evidence') {
    exit(_evidence(args, option, registry, repoRoot, site, result));
  }
  if (command == 'live') {
    exit(await _live(result));
  }
  for (final problem in result.problems) {
    stdout.writeln(problem);
  }
  if (result.problems.isNotEmpty) {
    stdout.writeln('${result.problems.length} problem(s)');
    exit(1);
  }

  final stale = await _generated(
    registry,
    repoRoot,
    site,
    result,
    write: command == 'generate',
  );
  if (command == 'freeze' || command == 'release-check') {
    final package = args.length > 1 && !args[1].startsWith('--')
        ? args[1]
        : null;
    final version = site.versions[package];
    // A package with no catalog (core) has nothing to freeze.
    if (package == null ||
        version == null ||
        !site.snapshots.containsKey(package)) {
      stderr.writeln(
        '$command needs a package with a snapshot: '
        '${site.snapshots.keys.join(', ')}',
      );
      exit(64);
    }
    final snapshot = freezeJson(
      freezeSnapshot(result.entries, package, version),
    );
    final published = publishedFile(registry, package, version);
    if (command == 'freeze') {
      published
        ..createSync(recursive: true)
        ..writeAsStringSync(snapshot);
      stdout.writeln('wrote ${p.relative(published.path, from: repoRoot)}');
      exit(0);
    }
    final reasons = <String>[
      for (final path in uncommittedUnder(repoRoot, [
        'model_registry',
        'tool/model_registry',
        'packages/$package',
      ]))
        '$path is not committed: the check would not stand for HEAD',
      if (stale > 0) '$stale generated file(s) not current',
      if (!published.existsSync() || published.readAsStringSync() != snapshot)
        '${p.relative(published.path, from: repoRoot)} is not what '
            '`dart run bin/registry.dart freeze $package` writes',
      for (final (c, status) in unverified(
        site,
        result.entries,
        critical,
        package,
      ))
        '${c.variant} on ${c.host} ${c.backend} is $status, not verified '
            '(${c.what})',
    ];
    if (reasons.isEmpty) {
      stdout.writeln('$package $version: ready to publish');
      exit(0);
    }
    reasons.forEach(stdout.writeln);
    stdout.writeln(
      '$package $version: ${reasons.length} reason(s) not to publish',
    );
    exit(1);
  }
  if (stale > 0) exit(1);
  final pending = {for (final x in gate.pending) x.awaitsFreeze!.$1};
  stdout.writeln(
    '${result.entries.length} models, ${result.variantCount} variants: '
    '${pending.isEmpty ? 'ok' : 'ok but for the freeze of ${pending.join(', ')}'}',
  );
}

/// Writes ([write]) or compares every generated file; returns how many are
/// not current.
Future<int> _generated(
  Directory registry,
  String repoRoot,
  SiteInputs site,
  CheckResult result, {
  required bool write,
}) async {
  var stale = 0;
  for (final file in [
    ...generateAll(registry, result.entries),
    ...generateSite(site, result.entries),
  ]) {
    final target = File(p.join(repoRoot, file.path));
    final content = file.path.endsWith('.dart')
        ? await formatDart(file.content)
        : file.content;
    final current = target.existsSync() ? target.readAsStringSync() : null;
    if (current == content) continue;
    if (write) {
      target
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      stdout.writeln('wrote ${file.path}');
    } else {
      stale++;
      stdout.writeln(
        '${file.path}: ${current == null ? 'missing' : 'stale'}; run '
        '`dart run bin/registry.dart generate`',
      );
    }
  }
  return stale;
}

/// `evidence`: one run's log into one evidence file. Exit code.
int _evidence(
  List<String> args,
  String? Function(String) option,
  Directory registry,
  String repoRoot,
  SiteInputs site,
  CheckResult result,
) {
  if (result.problems.isNotEmpty) {
    result.problems.forEach(stdout.writeln);
    stdout.writeln('fix the registry first');
    return 1;
  }
  const valued = {'--device', '--log-url', '--date', '--registry'};
  final logs = <String>[];
  for (var i = 1; i < args.length; i++) {
    if (valued.contains(args[i])) {
      i++;
    } else if (!args[i].startsWith('--')) {
      logs.add(args[i]);
    }
  }
  final device = option('--device');
  if (device == null || logs.isEmpty) {
    stderr.writeln('evidence needs --device and at least one log');
    return 64;
  }
  String git(List<String> a) {
    final r = Process.runSync('git', a, workingDirectory: repoRoot);
    if (r.exitCode != 0) throw StateError('git ${a.join(' ')}: ${r.stderr}');
    return (r.stdout as String).trim();
  }

  // What ran is what the packages' code is at HEAD: an edit to it that is not
  // committed makes the commit a false record.
  final dirty = git([
    'status',
    '--porcelain',
    '--',
    'packages/*/lib',
    'packages/*/hook',
    'packages/*/native',
  ]);
  if (dirty.isNotEmpty && !args.contains('--allow-dirty')) {
    stderr.writeln(
      'uncommitted changes under packages/; commit them first:\n$dirty',
    );
    return 1;
  }
  final bytes = <int>[];
  final lines = <EvidenceLine>[];
  final problems = <String>[];
  for (final log in logs) {
    final text = File(log).readAsStringSync();
    bytes.addAll(utf8.encode(text));
    lines.addAll(
      parseEvidenceLog(text, (line, m) => problems.add('$log:$line: $m')),
    );
  }
  final date =
      option('--date') ??
      DateTime.now().toUtc().toIso8601String().substring(0, 10);
  final host = lines.isEmpty ? 'none' : lines.first.host;
  final slug = device
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  var name = '${date}_${host}_$slug.json';
  for (
    var n = 2;
    File(p.join(registry.path, 'evidence', name)).existsSync();
    n++
  ) {
    name = '${date}_${host}_$slug-$n.json';
  }
  final run = runFromLines(
    lines,
    file: name,
    date: date,
    device: device,
    commit: git(['rev-parse', 'HEAD']),
    packages: site.versions,
    native: nativeKey(repoRoot, host, site.versions),
    logSha256: sha256Hex(bytes),
    logUrl: option('--log-url'),
    error: problems.add,
  );
  if (run != null) {
    final found = <Problem>[];
    checkEvidence(site, result.entries, found, runs: [run]);
    problems.addAll(found.map((f) => '$f'));
  }
  if (problems.isNotEmpty || run == null) {
    problems.forEach(stdout.writeln);
    stdout.writeln('nothing written');
    return 1;
  }
  final out = File(p.join(registry.path, 'evidence', name))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(run.toJson())}\n',
    );
  final cells = run.cells.values.fold(0, (n, b) => n + b.length);
  stdout.writeln(
    'wrote ${p.relative(out.path, from: repoRoot)}: $cells cell(s) on '
    '${run.host}; run `dart run bin/registry.dart generate`',
  );
  return 0;
}

/// `live`: every pinned file against Hugging Face. Exit code.
Future<int> _live(CheckResult result) async {
  if (result.problems.isNotEmpty) {
    result.problems.forEach(stdout.writeln);
    return 1;
  }
  final artifacts = liveArtifacts([
    for (final e in result.entries)
      for (final v in (e.data['variants'] as List? ?? const []))
        if (v case final Map<String, Object?> variant) variant,
  ]);
  final token = Platform.environment['HF_TOKEN'];
  final results = await checkLive(
    artifacts,
    token: token == null || token.isEmpty ? null : token,
  );
  final summary = liveSummary(results);
  stdout.write(summary);
  final out = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (out != null && out.isNotEmpty) {
    File(out).writeAsStringSync(summary, mode: FileMode.append);
  }
  // A file not checked (noAccess) fails as one that is wrong does.
  return liveFailed(results) ? 1 : 0;
}

/// model_registry/ at the repo root, two levels above this package.
String _defaultRegistry() {
  final package = p.dirname(p.dirname(p.fromUri(Platform.script)));
  return p.normalize(p.join(package, '..', '..', 'model_registry'));
}
