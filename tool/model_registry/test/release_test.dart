// release-check passes only when the inputs it read are committed.

import 'dart:io';

import 'package:model_registry/release.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('an uncommitted or untracked file under the paths is named', () {
    final repo = Directory.systemTemp.createTempSync('release_check_repo');
    addTearDown(() => repo.deleteSync(recursive: true));
    void git(List<String> args) {
      final r = Process.runSync('git', args, workingDirectory: repo.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    git(['init', '-q']);
    git(['config', 'user.email', 't@example.com']);
    git(['config', 'user.name', 't']);
    File(p.join(repo.path, 'model_registry', 'a.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a: 1\n');
    File(p.join(repo.path, 'other.txt')).writeAsStringSync('x');
    git(['add', '-A']);
    git(['commit', '-qm', 'init']);
    expect(uncommittedUnder(repo.path, ['model_registry']), isEmpty);

    File(
      p.join(repo.path, 'model_registry', 'a.yaml'),
    ).writeAsStringSync('a: 2\n');
    File(p.join(repo.path, 'model_registry', 'evidence', 'new.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    File(p.join(repo.path, 'other.txt')).writeAsStringSync('y');
    expect(uncommittedUnder(repo.path, ['model_registry']), [
      'model_registry/a.yaml',
      'model_registry/evidence/new.json',
    ]);

    // An example's pubspec.lock that `pub get` rewrote is not one.
    final lock = File(p.join(repo.path, 'pkg', 'example', 'pubspec.lock'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    git(['add', '-A']);
    git(['commit', '-qm', 'lock']);
    lock.writeAsStringSync('b');
    expect(uncommittedUnder(repo.path, ['pkg']), isEmpty);
  });

  test('a snapshot git once held counts as shipped; when git cannot say, '
      'it counts as shipped too', () {
    final repo = Directory.systemTemp.createTempSync('release_committed');
    addTearDown(() => repo.deleteSync(recursive: true));
    // Not a repository: git fails, so the answer is the closed one.
    expect(everCommitted(repo.path, 'published/x/1.0.0.json'), isTrue);
    void git(List<String> args) {
      final r = Process.runSync('git', args, workingDirectory: repo.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    git(['init', '-q']);
    git(['config', 'user.email', 't@example.com']);
    git(['config', 'user.name', 't']);
    File(p.join(repo.path, 'other.txt')).writeAsStringSync('x');
    git(['add', '-A']);
    git(['commit', '-qm', 'init']);
    expect(everCommitted(repo.path, 'published/x/1.0.0.json'), isFalse);
    File(p.join(repo.path, 'published', 'x', '1.0.0.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    git(['add', '-A']);
    git(['commit', '-qm', 'freeze']);
    File(p.join(repo.path, 'published', 'x', '1.0.0.json')).deleteSync();
    expect(everCommitted(repo.path, 'published/x/1.0.0.json'), isTrue);
  });

  test('without git, the answers are the closed ones, not a stack trace', () {
    final repo = Directory.systemTemp.createTempSync('release_no_git');
    addTearDown(() => repo.deleteSync(recursive: true));
    const missing = 'git-that-is-not-installed';
    expect(
      everCommitted(repo.path, 'published/x/1.0.0.json', git: missing),
      isTrue,
    );
    expect(uncommittedUnder(repo.path, ['model_registry'], git: missing), [
      startsWith('git could not run'),
    ]);
  });
}
