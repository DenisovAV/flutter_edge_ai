@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The example's assets: entry cannot reach outside its package, so it keeps
// a copy of core's golden; this keeps the copy exact.
void main() {
  test('example golden is identical to core golden', () {
    final copy = File('example/assets/goldens/eg2_text_golden.json');
    final core = File(
      '../flutter_edge_ai/example/integration_test/goldens/eg2_text_golden.json',
    );
    expect(
      copy.readAsStringSync(),
      core.readAsStringSync(),
      reason: 'Copy ${core.path} over ${copy.path}.',
    );
  });
}
