// The package's app library re-exports litertlm_dart names one by one: an
// export of a whole litertlm_dart library would put that package's API, which
// changes with each upstream LiteRT-LM version, into this package's API.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every export of another package has a show list', () {
    final library = File(
      'lib/flutter_edge_ai_litertlm.dart',
    ).readAsStringSync();
    final exports = RegExp(
      r"export\s+'package:[^']+'([^;]*);",
    ).allMatches(library).toList();
    expect(exports, isNotEmpty);
    for (final export in exports) {
      expect(export.group(1), contains('show '), reason: export.group(0));
    }
  });
}
