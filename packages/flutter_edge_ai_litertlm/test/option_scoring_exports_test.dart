// The release gate (native/litert_lm/check_embedding_exports.py) refuses a
// libLiteRtLm that misses a C function option scoring calls. Its list must be
// the functions the code actually looks up: option_scoring_ffi.dart's, and
// the tokenizer calls of the client's tokenIds / detokenizeIds.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The C functions [source] calls through the generated bindings
/// (`b.litert_lm_…`, a call or a tear-off) and names in its failures, plus
/// `litert_lm_get_last_error_message` when it reads the last error
/// (`b.lastError`).
Set<String> _calledSymbols(String source) => {
  for (final m in RegExp(r"'(litert_lm_[a-z_]+)'").allMatches(source))
    m.group(1)!,
  for (final m in RegExp(r'\bb\.(litert_lm_[a-z_]+)\b').allMatches(source))
    m.group(1)!,
  if (source.contains('b.lastError')) 'litert_lm_get_last_error_message',
};

void main() {
  test('the gate lists every C function option scoring calls', () {
    final ffi = File('lib/src/ffi/option_scoring_ffi.dart').readAsStringSync();
    final client = File('lib/src/ffi/litert_lm_client.dart').readAsStringSync();
    final tokenizer = client.substring(
      client.indexOf('Future<List<int>> tokenIds('),
      client.indexOf('Future<String> renderUserMessage('),
    );
    final called = {..._calledSymbols(ffi), ..._calledSymbols(tokenizer)};
    final gate = File('native/litert_lm/check_embedding_exports.py')
        .readAsStringSync();
    final listed = RegExp(
      r'SCORING_SYMBOLS = \[(.*?)\]',
      dotAll: true,
    ).firstMatch(gate)!.group(1)!;
    final required = {
      for (final m in RegExp(r'"(litert_lm_[a-z_]+)"').allMatches(listed))
        m.group(1)!,
    };
    expect(called, isNotEmpty);
    expect(required, called);
  });
}
