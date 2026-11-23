// The symbol golden of litertlm_dart's public library: every name
// `package:litertlm_dart/litertlm_dart.dart` exports. The API mirrors
// LiteRT-LM's Kotlin and Swift APIs plus a few extras; a name that appears or
// goes here is reviewed against that rule, before it is published.
//
// Each export must name what it exports (`show`), so the show lists are the
// surface.
//
// Regenerate after an intended change (refused when CI is set):
//   UPDATE_GOLDENS=1 dart test test/public_surface_test.dart
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

final _library = File('lib/litertlm_dart.dart');
final _golden = File('test/public_surface.golden.txt');

List<String> _exportedNames(String source) {
  final names = <String>[];
  final export = RegExp(r"export\s+'([^']+)'([^;]*);");
  // A conditional export names its web arm; the names are the show list
  // (the web arm exports the same, members_test.dart holds them equal).
  final condition = RegExp(r"^if\s*\([^)]*\)\s*'[^']+'\s*");
  for (final m in export.allMatches(source)) {
    final clause = m.group(2)!.trim().replaceFirst(condition, '');
    if (!clause.startsWith('show')) {
      throw StateError('export ${m.group(1)} shows no list: $clause');
    }
    names.addAll(
      clause
          .substring('show'.length)
          .split(',')
          .map((n) => n.trim())
          .where((n) => n.isNotEmpty),
    );
  }
  return names..sort();
}

void main() {
  test('the public library exports exactly the golden names', () {
    final names = _exportedNames(_library.readAsStringSync());
    final rendered = '${names.join('\n')}\n';
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      if (Platform.environment.containsKey('CI')) {
        fail('UPDATE_GOLDENS is refused on CI');
      }
      _golden.writeAsStringSync(rendered);
    }
    expect(rendered, _golden.readAsStringSync());
  });

  test('an export without a show list is refused', () {
    expect(() => _exportedNames("export 'src/x.dart';"), throwsStateError);
  });
}
