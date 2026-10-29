// release-check stamps HEAD only when the inputs it read are committed.

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
  });
}
