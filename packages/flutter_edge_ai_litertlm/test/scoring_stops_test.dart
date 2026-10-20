// ScoringStops: the stop flags an option scorer's close() sets, VM-tested over
// real native memory without an engine.
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stopAll sets the tracked flags only, and a flag untracked before it '
      'is freed is never written', () {
    final stops = ScoringStops();
    final kept = calloc<Int32>();
    final done = calloc<Int32>();
    try {
      stops.track(kept);
      stops.track(done);
      stops.untrack(done);
      expect(stops.isStopped, isFalse);
      stops.stopAll();
      expect(stops.isStopped, isTrue);
      expect(kept.value, 1);
      expect(done.value, 0, reason: 'an untracked run is not touched');
    } finally {
      calloc.free(kept);
      calloc.free(done);
    }
  });

  test('a flag tracked after stopAll starts stopped', () {
    final stops = ScoringStops()..stopAll();
    final late = calloc<Int32>();
    try {
      stops.track(late);
      expect(late.value, 1);
    } finally {
      stops.untrack(late);
      calloc.free(late);
    }
  });
}
