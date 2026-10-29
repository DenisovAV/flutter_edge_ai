// The release gate (native/litert_lm/check_embedding_exports.py) refuses a
// bundle whose LiteRT C library misses a function LiteRtBindings looks up
// (#747 added the opaque-options three the speech GPU options use). Its list
// must be the lookups the bindings actually make.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the gate lists every LiteRT C function LiteRtBindings looks up', () {
    final bindings = File(
      'lib/src/ffi/litert_bindings.dart',
    ).readAsStringSync();
    final looked = {
      for (final m in RegExp(
        r">\(\s*'(LiteRt[A-Za-z0-9]+)'\s*,?\s*\)",
      ).allMatches(bindings))
        m.group(1)!,
    };
    final gate = File(
      'native/litert_lm/check_embedding_exports.py',
    ).readAsStringSync();
    final listed = RegExp(
      r'LITERT_BINDINGS_SYMBOLS = \[(.*?)\]',
      dotAll: true,
    ).firstMatch(gate)!.group(1)!;
    final required = {
      for (final m in RegExp(r'"(LiteRt[A-Za-z0-9]+)"').allMatches(listed))
        m.group(1)!,
    };
    expect(
      looked,
      containsAll(<String>[
        'LiteRtCreateOpaqueOptions',
        'LiteRtAddOpaqueOptions',
        'LiteRtDestroyOpaqueOptions',
      ]),
    );
    expect(required, looked);
  });
}
