@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('example golden is byte-identical to core golden', () {
    final copy = File('example/assets/goldens/eg2_text_golden.json');
    final core = File(
      '../flutter_edge_ai/example/integration_test/goldens/eg2_text_golden.json',
    );
    expect(copy.readAsBytesSync(), core.readAsBytesSync());
  });
}
