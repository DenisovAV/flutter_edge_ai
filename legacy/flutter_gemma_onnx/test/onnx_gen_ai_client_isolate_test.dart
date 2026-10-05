// Proves the GenAiFfiClient <-> worker-isolate spawn/handshake protocol
// (hardened plan Phase 3, Task 1 gate: "a bare dart test-level isolate
// round-trip test proves the descriptor/port protocol"). Deliberately does
// NOT dlopen a real ORT-GenAI build — it exercises the FAILURE path (no
// libsDir override, so the worker's dlopen of the platform-default name
// fails), which still round-trips through the full isolate machinery: spawn
// -> load attempt -> failure -> `_Ready`/error handshake -> clean isolate
// teardown, with no hang. The macOS host smoke test
// (onnx_generation_host_smoke_test.dart) is the success-path AOT boundary
// proof, per the same gate.
import 'package:flutter_gemma_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GenAiFfiClient isolate handshake', () {
    test(
      'load() surfaces a clean error (not a hang) when the dylib is missing',
      () async {
        final client = GenAiFfiClient();

        await expectLater(
          client.load('/nonexistent/model-dir'),
          throwsA(anything),
        );
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('shutdown() before a successful load() is a safe no-op', () async {
      final client = GenAiFfiClient();
      try {
        await client.load('/nonexistent/model-dir');
      } catch (_) {
        // Expected — covered by the previous test.
      }

      await client.shutdown();
      await client.shutdown(); // idempotent
    });

    test(
      'generate()/countTokens() before load() fail loud, not silently',
      () async {
        final client = GenAiFfiClient();

        await expectLater(
          client.generate(const GenAiTurn(userContent: 'hi')).toList(),
          throwsA(anything),
        );
        expect(() => client.countTokens('hi'), throwsStateError);
      },
    );
  });
}
