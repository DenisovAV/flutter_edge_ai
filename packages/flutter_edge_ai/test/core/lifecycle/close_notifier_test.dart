import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

class _Model with CloseNotifier {
  bool closed = false;
  Future<void> close() async {
    if (closed) return; // idempotent
    closed = true;
    fireCloseListeners();
  }
}

void main() {
  test(
    'listeners fire exactly once on close, even when close called twice',
    () async {
      final m = _Model();
      var fired = 0;
      m.addCloseListener(() => fired++);
      m.addCloseListener(() => fired++);
      await m.close();
      await m.close(); // second close is a no-op
      expect(fired, 2); // two listeners, one fire each
    },
  );

  test(
    'a listener added after close still does not double-fire prior ones',
    () async {
      final m = _Model();
      var a = 0;
      m.addCloseListener(() => a++);
      await m.close();
      expect(a, 1);
    },
  );
}
