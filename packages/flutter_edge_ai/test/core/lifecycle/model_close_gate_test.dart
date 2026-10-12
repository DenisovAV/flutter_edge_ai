import 'dart:async';

import 'package:flutter_edge_ai/core/lifecycle/model_close_gate.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('waits for the close, then lets the build through', () async {
    final gate = ModelCloseGate();
    final model = _ClosingModel();

    var waited = false;
    final wait = gate
        .closeAndWait(model, label: 'a')
        .then((_) => waited = true);
    await pumpEventQueue();
    expect(gate.isClosing, isTrue);
    expect(waited, isFalse);

    model.finish();
    await wait;
    expect(waited, isTrue);
    expect(gate.isClosing, isFalse);
  });

  test('a close that never ends times out, with one deadline for every '
      'caller', () async {
    final gate = ModelCloseGate(const Duration(milliseconds: 100));
    final model = _ClosingModel();

    final first = expectLater(
      gate.closeAndWait(model, label: 'stuck-model'),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // A caller arriving late gets what is left of the deadline, not a fresh
    // limit.
    final watch = Stopwatch()..start();
    await expectLater(
      gate.wait(),
      throwsA(
        isA<TimeoutException>().having(
          (e) => e.message,
          'message',
          allOf(contains('stuck-model'), contains('0.1 s')),
        ),
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 80)));
    await first;
    // The close keeps running, and the gate holds builds back until it ends.
    expect(gate.isClosing, isTrue);
    model.finish();
    await pumpEventQueue();
    expect(gate.isClosing, isFalse);
  });

  test('a close that fails is not passed on to the caller', () async {
    final gate = ModelCloseGate();
    final model = _ClosingModel()..error = StateError('native close failed');

    final wait = gate.closeAndWait(model, label: 'a');
    model.finish();
    await expectLater(wait, completes);
    expect(gate.isClosing, isFalse);
  });
}

class _ClosingModel implements InferenceModel {
  final _done = Completer<void>();
  Object? error;

  void finish() {
    if (error case final e?) {
      _done.completeError(e);
    } else {
      _done.complete();
    }
  }

  @override
  Future<void> close() => _done.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
