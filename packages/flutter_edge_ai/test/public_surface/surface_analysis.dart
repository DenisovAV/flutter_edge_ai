// What the public-surface goldens share: one analyzer session over this
// package, the export namespace of a public library, the CI guard on
// UPDATE_GOLDENS, and the comparison that names what drifted.
//
// Not a test file (no `_test.dart` suffix): the two golden suites import it.

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:flutter_test/flutter_test.dart';

AnalysisContextCollection? _collection;

AnalysisContextCollection _contexts() =>
    _collection ??= AnalysisContextCollection(
      includedPaths: [Directory.current.absolute.path],
      sdkPath: _dartSdkPath(),
    );

/// The export namespace of `lib/<library>`, resolved; throws when the library
/// does not analyze cleanly, so a broken library never regenerates a golden.
Future<Map<String, Element>> exportNamespace(String library) async {
  final path = File('lib/$library').absolute.path;
  final result = await _contexts()
      .contextFor(path)
      .currentSession
      .getResolvedLibrary(path);
  if (result is! ResolvedLibraryResult) {
    throw StateError('Cannot resolve $path: $result');
  }
  final errors = result.units
      .expand((unit) => unit.diagnostics)
      .where((d) => d.severity.name == 'error')
      .toList();
  if (errors.isNotEmpty) {
    throw StateError('$library does not analyze cleanly: $errors');
  }
  return result.element.exportNamespace.definedNames2;
}

/// Compares [actual] with [golden], or rewrites [golden] under
/// `UPDATE_GOLDENS=1` — refused while `CI` is set, because a regenerated
/// golden always matches. [describeDrift] turns the two texts into the
/// failure message.
void expectGolden(
  File golden,
  String actual,
  String Function(String expected, String actual) describeDrift,
) {
  final update = Platform.environment['UPDATE_GOLDENS'] == '1';
  final onCi = (Platform.environment['CI'] ?? '').isNotEmpty;
  if (update) {
    if (onCi) {
      fail(
        'UPDATE_GOLDENS=1 is refused while CI is set: a regenerated golden '
        'always matches. Regenerate locally and commit the reviewed diff.',
      );
    }
    golden.writeAsStringSync(actual);
    return;
  }
  expect(
    golden.existsSync(),
    isTrue,
    reason: 'Missing ${golden.path}. Run with UPDATE_GOLDENS=1 to create it.',
  );
  final expected = golden.readAsStringSync();
  if (actual != expected) fail(describeDrift(expected, actual));
}

/// The lines of [expected] and [actual] that differ, as `+`/`-` lists.
String describeLineDrift(String what, String expected, String actual) {
  Set<String> body(String text) =>
      text.split('\n').where((l) => l.isNotEmpty && !l.startsWith('#')).toSet();
  final before = body(expected);
  final after = body(actual);
  final added = after.difference(before).toList()..sort();
  final removed = before.difference(after).toList()..sort();
  return [
    '$what changed.',
    if (added.isNotEmpty) 'Added:\n${added.map((l) => '  + $l').join('\n')}',
    if (removed.isNotEmpty)
      'Removed:\n${removed.map((l) => '  - $l').join('\n')}',
    'If this is intended, regenerate the golden with UPDATE_GOLDENS=1 and '
        'review the diff.',
  ].join('\n');
}

/// The Dart SDK the analyzer should use. `flutter test` runs these files in
/// flutter_tester, whose executable is not inside a Dart SDK, so find the SDK
/// Flutter ships in `<flutter>/bin/cache/dart-sdk`.
String _dartSdkPath() {
  final candidates = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final root?)
      '$root/bin/cache/dart-sdk',
  ];
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    candidates
      ..add('${dir.path}/dart-sdk')
      ..add(dir.path);
    dir = dir.parent;
  }
  for (final candidate in candidates) {
    if (File('$candidate/version').existsSync() &&
        Directory('$candidate/lib/core').existsSync()) {
      return candidate;
    }
  }
  throw StateError(
    'No Dart SDK found near ${Platform.resolvedExecutable}; set FLUTTER_ROOT.',
  );
}
