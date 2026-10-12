// MEASUREMENT, not a regression gate: what the request pump's per-request
// yield (W2) costs on the web page. It used to be a zero timer
// (`Future<void>.delayed(Duration.zero)`), which browsers clamp to >= 4 ms
// once timers nest, so every request paid ≈ 4.3 ms however fast the pass was
// (Chrome 155, GCE VM: 864–934 ms for the embedAll below). Since stage 3b the
// inline host yields with a MessageChannel message on web
// (`event_loop_yield_web.dart`), which is not clamped.
//
// A pass that answers at once (`Future.value`), behind core's inline host and
// facade: `embedAll` of 200 short texts, printed as total and per-request ms,
// next to 200 bare zero-timer awaits (the clamp baseline) and 200 bare
// MessageChannel yields on the same page. Asserts only that everything
// completed; the numbers are for the record.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/inline_host_yield_cost_test.dart
@TestOn('browser')
library;

import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_host_web.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/embedding/event_loop_yield_web.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every request at once: whatever the measurement shows is the
/// host's and the facade's, not the engine's.
final class _InstantPass extends EmbeddingPass {
  @override
  Future<EmbeddingPassInfo> load() async =>
      const EmbeddingPassInfo(dimension: 4);

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) =>
      Future.value(List<double>.filled(4, 0.0));

  @override
  Future<void> close() async {}
}

EmbeddingPass _buildInstantPass(String _) => _InstantPass();

String _ms(Duration d, int n) =>
    '${d.inMilliseconds} ms total, '
    '${(d.inMicroseconds / n / 1000).toStringAsFixed(2)} ms per request';

void main() {
  test('embedAll of 200 short texts through the inline host (prints the '
      'timing)', () async {
    const count = 200;

    // Baseline: 200 sequential zero-timer awaits, nothing else.
    final bare = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    bare.stop();

    // What the inline host now awaits before every request.
    final channel = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      await yieldToEventLoop();
    }
    channel.stop();

    final host = await startEmbeddingHost(
      const EmbeddingPassDescriptor<String>(
        engineTag: 'Instant',
        factory: _buildInstantPass,
        config: 'instant',
        activeBackend: null,
      ),
      declaredMedia: const {},
      label: 'yield-cost',
    );
    final model = CommonEmbeddingModel.withHost(host, engine: 'Instant');
    final inputs = [
      for (var i = 0; i < count; i++) EmbeddingInput.text('text $i'),
    ];
    // Warm-up, so the first-call costs of the page are not in the number.
    await model.embedAll(inputs.take(10).toList(), taskType: TaskType.none);

    final timed = Stopwatch()..start();
    final vectors = await model.embedAll(inputs, taskType: TaskType.none);
    timed.stop();

    // ignore: avoid_print
    print(
      '[inline-host yield cost] embedAll of $count short texts: '
      '${_ms(timed.elapsed, count)}',
    );
    // ignore: avoid_print
    print(
      '[inline-host yield cost] $count bare zero-timer awaits: '
      '${_ms(bare.elapsed, count)}',
    );
    // ignore: avoid_print
    print(
      '[inline-host yield cost] $count bare MessageChannel yields: '
      '${_ms(channel.elapsed, count)}',
    );

    expect(vectors, hasLength(count));
    await model.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
