// Each key rule's scenario must FAIL with that rule disabled: a scenario
// that stays green without its rule tests nothing.
import 'package:flutter_edge_ai_any/src/logic/engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'scenarios.dart';

void main() {
  for (final MapEntry(key: name, value: (scenario, rule))
      in scenarios.entries) {
    test('without "$rule", "$name" fails', () async {
      final w = World();
      debugEngineMutations.add(rule);
      Object? failure;
      try {
        await scenario(w);
      } catch (e) {
        failure = e;
      } finally {
        debugEngineMutations.clear();
        await w.dispose();
      }
      expect(
        failure,
        isA<TestFailure>(),
        reason: 'the scenario passed (or broke otherwise) without $rule',
      );
    });
  }
}
