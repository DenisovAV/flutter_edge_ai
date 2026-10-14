// The VM's fingerprints of the model-free fit fixture, which the browser test
// (test/web/decider_web_test.dart) compares the web fit with.

import 'package:flutter_edge_ai/src/decision/decider_fit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fit_fingerprint.dart';

void main() {
  final cases = <(int, bool), FitFingerprint>{
    (10, false): vmFingerprint10,
    (10, true): vmFingerprint10Linear,
    (50, false): vmFingerprint50,
    (50, true): vmFingerprint50Linear,
    (150, false): vmFingerprint150,
    (150, true): vmFingerprint150Linear,
  };
  for (final MapEntry(key: (c, linear), value: expected) in cases.entries) {
    test('$c options × 10, ${linear ? 'linear' : 'centroid'}', () async {
      final fit = await fitDecider(fingerprintRequest(c, linear: linear));
      expect(fingerprintOf(fit), expected);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
