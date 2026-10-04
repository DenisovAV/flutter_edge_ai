// Fail when a package would be published without a file its own pubspec
// declares as a Flutter asset.
//
// flutter_edge_ai_agent 0.2.6 (and flutter_gemma_agent 0.2.6 before the
// rename) reached pub.dev without a single bundled SKILL.md: `.pubignore`
// drops `**/*.md` and re-included only README.md and CHANGELOG.md (#578).
// Nothing failed. The tests read the skills from the repo, where they exist,
// and the published archive is the only place the gap shows — so this asks
// pub what it would publish instead of re-implementing `.pubignore` rules.
//
// For every package under packages/ whose pubspec has a `flutter: assets:`
// list, this runs `flutter pub publish --dry-run`, rebuilds the file list from
// the tree it prints, and checks every declared asset against it: each file
// directly inside a directory entry (Flutter does not recurse into
// subdirectories, so neither does this) and each file entry.
//
// Run from the repo root:
//   dart tool/check_published_assets.dart
// Exit 0: every declared asset would be published. Exit 1: one would not, or a
// dry run printed no file tree to check against.
import 'dart:io';

Future<void> main() async {
  final packages =
      Directory('packages').listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final failures = <String>[];
  var checked = 0;

  for (final package in packages) {
    final pubspec = File('${package.path}/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final entries = flutterAssetEntries(pubspec.readAsLinesSync());
    if (entries.isEmpty) continue;
    checked++;

    final declared = declaredAssetFiles(package.path, entries);
    final dryRun = await Process.run(
      'flutter',
      ['pub', 'publish', '--dry-run'],
      workingDirectory: package.path,
      runInShell: true,
    );
    final published = publishedFiles('${dryRun.stdout}');
    if (published.isEmpty) {
      failures.add(
        '${package.path}: `flutter pub publish --dry-run` printed no file '
        'tree (exit ${dryRun.exitCode}):\n${dryRun.stdout}${dryRun.stderr}',
      );
      continue;
    }

    final missing = declared.where((f) => !published.contains(f)).toList();
    if (missing.isEmpty) {
      stdout.writeln(
        '${package.path}: all ${declared.length} declared asset files '
        'would be published',
      );
    } else {
      failures.add(
        '${package.path}: declared in pubspec.yaml `flutter: assets:` but '
        'left out of the published package (check .pubignore):\n'
        '${missing.map((f) => '  $f').join('\n')}',
      );
    }
  }

  if (checked == 0) {
    // The agent package declares assets today; finding none means this
    // parser no longer reads the pubspecs, not that there is nothing to check.
    failures.add('no package under packages/ declares `flutter: assets:`');
  }
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n\n'));
    exit(1);
  }
}

/// The `flutter: assets:` entries of a pubspec, read line by line: the
/// tool scripts here use only dart:io, and the layout is the one
/// `flutter create` writes.
List<String> flutterAssetEntries(List<String> lines) {
  final entries = <String>[];
  var inFlutter = false;
  var inAssets = false;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final indent = line.length - line.trimLeft().length;
    if (indent == 0) {
      inFlutter = trimmed == 'flutter:';
      inAssets = false;
    } else if (inFlutter && indent == 2) {
      inAssets = trimmed == 'assets:';
    } else if (inAssets && trimmed.startsWith('- ')) {
      entries.add(trimmed.substring(2).trim());
    }
  }
  return entries;
}

/// The files [entries] declare, relative to the package: every non-hidden
/// file directly inside a directory entry, and each file entry as written.
List<String> declaredAssetFiles(String packageDir, List<String> entries) {
  final files = <String>[];
  for (final entry in entries) {
    if (entry.endsWith('/')) {
      final dir = Directory('$packageDir/$entry');
      if (!dir.existsSync()) {
        files.add(entry); // reported as missing: a declared directory is gone
        continue;
      }
      final names =
          dir
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((name) => !name.startsWith('.'))
              .toList()
            ..sort();
      files.addAll(names.map((name) => '$entry$name'));
    } else {
      files.add(entry);
    }
  }
  return files;
}

final _treeLine = RegExp(r'^((?:│   |    )*)(?:├── |└── )(.+)$');
final _fileSize = RegExp(r' \(<?\d+(?:\.\d+)? [KMG]?B\)$');

/// Rebuilds package-relative file paths from the tree `pub publish --dry-run`
/// prints. A file line ends in its size; a line without one is a directory.
Set<String> publishedFiles(String dryRunOutput) {
  final files = <String>{};
  final dirs = <String>[];
  for (final line in dryRunOutput.split('\n')) {
    final match = _treeLine.firstMatch(line.trimRight());
    if (match == null) continue;
    final depth = match.group(1)!.length ~/ 4;
    final name = match.group(2)!;
    if (dirs.length > depth) dirs.removeRange(depth, dirs.length);
    final size = _fileSize.firstMatch(name);
    if (size == null) {
      dirs.add(name);
    } else {
      files.add([...dirs, name.substring(0, size.start)].join('/'));
    }
  }
  return files;
}
