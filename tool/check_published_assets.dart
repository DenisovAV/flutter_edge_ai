// Fail when a package would be published without a file that consumers read
// from the published package.
//
// Every flutter_edge_ai_agent release up to 0.2.6 (and every
// flutter_gemma_agent release before the rename) reached pub.dev without a
// single bundled SKILL.md: `.pubignore` dropped `**/*.md` and re-included only
// README.md and CHANGELOG.md (#578). Nothing failed. The tests read the skills
// from the repo, where they exist, and the published archive is the only place
// the gap shows — so this asks pub what it would publish instead of
// re-implementing `.pubignore` rules.
//
// For every workspace package (the root pubspec's `workspace:` list) it
// requires:
//   - each `flutter: assets:` entry of the pubspec: every git-tracked file
//     directly inside a directory entry (Flutter does not recurse into
//     subdirectories, so neither does this) and each file entry;
//   - every git-tracked file under a path in [publishedTrees], recursively.
//     These are read from the published package without being Flutter assets.
// For each package with anything required it runs
// `flutter pub publish --dry-run` and rebuilds the file list from the tree pub
// prints.
//
// macOS and Linux only: on Windows pub draws the tree in ASCII and the output
// arrives in the console code page. CI runs it on Ubuntu, releases on macOS.
//
// Run from the repo root:
//   dart tool/check_published_assets.dart
// Exit 0: every required file would be published. Exit 1: one would not, a
// dry run printed no file tree, git listed nothing for a required path, a
// pubspec has an `assets:` list this script could not read, or a package in
// [publishedTrees] / [assetPackages] was not checked.
import 'dart:convert';
import 'dart:io';

/// Paths, per package, that consumers read from the published archive
/// although the pubspec does not declare them as Flutter assets.
const publishedTrees = {
  // `dart run skills@ get` installs skills/ from the package on disk; the
  // same `**/*.md` rule stripped it once (#505). Apps copy web/cache_api.js
  // and web/opfs_helper.js into their own web/, and `.pubignore` re-includes
  // them one by one after excluding `web/*.js` — the #578 shape.
  'packages/flutter_edge_ai': ['skills', 'web'],
  // Apps copy the four LiteRT.js files; the build hook runs the staging
  // script from the package root and skips staging without it. tool/web_build
  // is the recipe that rebuilds web/ — lockfile and tests included — and an
  // unanchored `test/` in .pubignore once dropped its tests.
  'packages/flutter_edge_ai_litertlm': [
    'web',
    'tool/stage_macos_companions.sh',
    'tool/web_build',
  ],
  // Apps copy the vec0-enabled sqlite3.wasm into their web root.
  'packages/flutter_edge_ai_sqlite': ['web'],
};

/// Packages that declare `flutter: assets:` today. One of them being skipped
/// means the pubspec parser stopped reading it, not that there is nothing to
/// check.
const assetPackages = {'packages/flutter_edge_ai_agent'};

Future<void> main() async {
  if (!Platform.isMacOS && !Platform.isLinux) {
    stderr.writeln('check_published_assets.dart runs on macOS and Linux only');
    exit(1);
  }
  final failures = <String>[];
  final checked = <String>{};

  for (final package in workspacePackages(File('pubspec.yaml'))) {
    final lines = File('$package/pubspec.yaml').readAsLinesSync();
    final entries = flutterAssetEntries(lines);
    if (entries.isEmpty && hasAssetsKey(lines)) {
      failures.add(
        '$package: pubspec.yaml has a `flutter: assets:` list this script '
        'could not read',
      );
      continue;
    }
    final trees = publishedTrees[package] ?? const <String>[];
    if (entries.isEmpty && trees.isEmpty) continue;

    final required = <String>[];
    var listed = true;
    for (final entry in entries) {
      final files = await trackedFiles(package, entry);
      if (files == null) {
        failures.add('$package: git ls-files failed for $entry');
        listed = false;
      } else if (entry.endsWith('/')) {
        final direct = files
            .where((f) => !f.substring(entry.length).contains('/'))
            .toList();
        if (direct.isEmpty) {
          failures.add('$package: asset directory $entry has no tracked files');
          listed = false;
        }
        required.addAll(direct);
      } else {
        // A file entry is required as written, tracked or not.
        required.add(entry);
      }
    }
    for (final tree in trees) {
      final files = await trackedFiles(package, tree);
      if (files == null || files.isEmpty) {
        failures.add(
          '$package: git tracks nothing at $tree, listed in publishedTrees',
        );
        listed = false;
      } else {
        required.addAll(files);
      }
    }
    if (!listed) continue;

    final dryRun = await Process.run(
      'flutter',
      ['pub', 'publish', '--dry-run'],
      workingDirectory: package,
      runInShell: true,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final published = publishedFiles('${dryRun.stdout}');
    if (published.isEmpty) {
      failures.add(
        '$package: `flutter pub publish --dry-run` printed no file tree '
        '(exit ${dryRun.exitCode}):\n${dryRun.stdout}${dryRun.stderr}',
      );
      continue;
    }
    checked.add(package);

    final missing = required.where((f) => !published.contains(f)).toList();
    if (missing.isEmpty) {
      // pub exits non-zero on validation warnings too (a dirty tree, an
      // outdated constraint); those are the release checklist's concern.
      final note = dryRun.exitCode == 0
          ? ''
          : ' (dry run exited ${dryRun.exitCode})';
      stdout.writeln(
        '$package: all ${required.length} required files would be '
        'published$note',
      );
    } else {
      failures.add(
        '$package: required at runtime but left out of the published '
        'package (check .pubignore):\n'
        '${missing.map((f) => '  $f').join('\n')}',
      );
    }
  }

  final unchecked = {
    ...assetPackages,
    ...publishedTrees.keys,
  }.difference(checked);
  if (unchecked.isNotEmpty) {
    failures.add('not checked: ${unchecked.join(', ')}');
  }
  if (failures.isNotEmpty) {
    stderr.writeln(failures.join('\n\n'));
    exit(1);
  }
}

/// The root pubspec's `workspace:` members, as written there.
List<String> workspacePackages(File rootPubspec) {
  final packages = <String>[];
  var inWorkspace = false;
  for (final line in rootPubspec.readAsLinesSync()) {
    final trimmed = _stripComment(line);
    if (trimmed.isEmpty) continue;
    if (!line.startsWith(' ')) {
      inWorkspace = trimmed == 'workspace:';
    } else if (inWorkspace && trimmed.startsWith('- ')) {
      packages.add(trimmed.substring(2).trim());
    }
  }
  return packages;
}

/// The `flutter: assets:` entries of a pubspec, read line by line: the
/// tool scripts here use only dart:io, and the layout is the one
/// `flutter create` writes. [hasAssetsKey] catches a layout it cannot read.
List<String> flutterAssetEntries(List<String> lines) {
  final entries = <String>[];
  var inFlutter = false;
  var inAssets = false;
  for (final line in lines) {
    final trimmed = _stripComment(line);
    if (trimmed.isEmpty) continue;
    final indent = line.length - line.trimLeft().length;
    if (indent == 0) {
      inFlutter = trimmed == 'flutter:';
      inAssets = false;
    } else if (inFlutter && indent == 2) {
      inAssets = trimmed == 'assets:';
    } else if (inAssets && trimmed.startsWith('- ')) {
      entries.add(_unquote(trimmed.substring(2).trim()));
    }
  }
  return entries;
}

/// Whether the top-level `flutter:` block has an `assets` key at all.
bool hasAssetsKey(List<String> lines) {
  var inFlutter = false;
  for (final line in lines) {
    final trimmed = _stripComment(line);
    if (trimmed.isEmpty) continue;
    if (!line.startsWith(' ')) {
      inFlutter = trimmed.startsWith('flutter:');
    } else if (inFlutter && trimmed.startsWith('assets')) {
      return true;
    }
  }
  return false;
}

String _stripComment(String line) =>
    line.replaceFirst(RegExp(r'(^|\s)#.*$'), '').trim();

String _unquote(String value) =>
    value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))
    ? value.substring(1, value.length - 1)
    : value;

/// Every git-tracked file at or under [path] in [packageDir], relative to the
/// package, or null when git fails. Tracked files are what a checkout ships;
/// requiring them keeps a stray local file from failing the check.
Future<List<String>?> trackedFiles(String packageDir, String path) async {
  final result = await Process.run(
    'git',
    ['ls-files', '-z', '--', path],
    workingDirectory: packageDir,
    stdoutEncoding: utf8,
  );
  if (result.exitCode != 0) return null;
  return '${result.stdout}'.split('\x00').where((f) => f.isNotEmpty).toList();
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
