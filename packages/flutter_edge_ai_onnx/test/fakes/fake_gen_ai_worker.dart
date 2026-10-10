// A fake ORT-GenAI worker — a REAL isolate, REAL ports, ZERO FFI. It runs the
// production worker loop (`serveGenAiWorker`, `lib/src/ffi/gen_ai_worker.dart`)
// over a scripted [GenAiWorkerEngine], so `test/gen_ai_client_lifecycle_test.dart`
// can inject it via `GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry)` and
// exercise the REAL client's dispatch/mutex/`_closed`-recheck machinery AND
// the real worker's queue/stop/close rules end-to-end (hardened plan Task
// 2b/2c) — something a `FakeGenAiClient`-based session test cannot reach,
// since that fake skips `GenAiFfiClient` entirely. This fake has NO FFI and
// no native pointers, so it cannot prove that the FFI engine's native handle
// teardown is use-after-free-safe — see `onnx_generation_host_smoke_test.dart`
// for that.
//
// Engine configuration — the `modelDir` passed to `GenAiFfiClient.load` —
// is JSON when the test needs it (anything else means the defaults):
//   {"log": "/tmp/x.log", "failLoad": true, "throwOnClose": true}
// - `log`: the engine appends one line per call (`load`, `generate`,
//   `count`, `reset`, `close`) to this file — the only way the test, on the
//   main isolate, can see what ran inside the worker. The writes are
//   synchronous and flushed, so a line is on disk before the call returns.
// - `failLoad`: `load` throws after it "allocated" something.
// - `throwOnClose`: `close` throws.
//
// Turn script — [GenAiTurn.userContent] — is JSON too (falls back to a single
// verbatim echo chunk if it doesn't parse):
//   {"chunks": ["a", "b"], "delayMs": 10, "echoIsFirstTurn": true}
// - `chunks`: pieces emitted in order, one per (simulated) decode step.
// - `delayMs`: real-clock delay before each chunk (0 = yield-only, still
//   enough for a queued StopSignal to land between chunks — mirrors the
//   real engine's per-token yield).
// - `echoIsFirstTurn`: when true, a marker chunk `[isFirstTurn=<bool>]` is
//   sent FIRST, echoing what the worker received on [GenAiTurn.isFirstTurn]
//   — lets a test assert the client-observable effect of `resetSession()`
//   without reaching into worker-private state.
// - `blockMs`: blocks the isolate synchronously this long before the first
//   chunk — a prompt's prefill, one native call nothing can interrupt.
// - `tailBlockMs`: once the chunks are done (or a stop broke them off), logs
//   `tail` and blocks the isolate synchronously this long before the turn
//   returns — a last native call, during which the test sends what it wants
//   queued behind the turn.
// - `kill`: when true, the isolate kills ITSELF (`Isolate.current.kill`)
//   instead of ever replying — simulates an unexpected native crash
//   mid-generation, same shape as `embedding_worker_test.dart`'s
//   `killMidRequest` fake mode. Never sends a Chunk/GenerateDone.
// - `crash`: when true, an uncaught error takes the isolate down at the
//   turn's first yield — a death mid-turn that reports its reason.
// - `throw`: when true, the turn throws — a native call that failed.
//
// countTokens text `block:<ms>` blocks the isolate synchronously that long.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_protocol.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_worker.dart';

Future<void> fakeGenAiWorkerEntry(WorkerInit init) =>
    serveGenAiWorker(init, _ScriptedEngine(init.modelDir));

/// Reads [json] as a JSON object, or null when it is not one.
Map<String, dynamic>? _objectOrNull(String json) {
  try {
    final decoded = jsonDecode(json);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

class _ScriptedEngine implements GenAiWorkerEngine {
  _ScriptedEngine(String modelDir) : _config = _objectOrNull(modelDir) ?? {};

  final Map<String, dynamic> _config;

  void _log(String line) {
    final path = _config['log'] as String?;
    if (path == null) return;
    File(path).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  @override
  Future<void> load() async {
    _log('load');
    if (_config['failLoad'] == true) {
      throw StateError('fake GenAI engine refused to load');
    }
  }

  @override
  Future<GenAiGenerationStats> generate(
    GenAiTurn turn, {
    required void Function(String piece) emit,
    required bool Function() stopRequested,
  }) async {
    _log('generate');
    final script = _objectOrNull(turn.userContent);
    if (script != null && script['kill'] == true) {
      // Simulate an unexpected native crash: the isolate dies while a
      // request is in flight, never sending a reply — what the client's
      // `onExit` handling (`_dispatch`'s `msg == null` branch) is built for.
      Isolate.current.kill(priority: Isolate.immediate);
      // Unreachable in practice — kill() terminates before this returns —
      // but the function must still return on every path.
      return const GenAiGenerationStats(
        promptTokens: 0,
        generatedTokens: 0,
        decodeMs: 0,
      );
    }
    final chunks = script == null
        ? [turn.userContent]
        : (script['chunks'] as List? ?? const []).cast<String>();
    final delayMs = (script?['delayMs'] as num?)?.toInt() ?? 0;
    final blockMs = (script?['blockMs'] as num?)?.toInt() ?? 0;

    if (blockMs > 0) sleep(Duration(milliseconds: blockMs));
    if (script?['throw'] == true) {
      throw StateError('fake generation failed');
    }
    if (script?['crash'] == true) {
      scheduleMicrotask(() => throw StateError('fake native crash'));
    }

    var generated = 0;
    if (script?['echoIsFirstTurn'] == true) {
      emit('[isFirstTurn=${turn.isFirstTurn}]');
      generated++;
    }

    for (final chunk in chunks) {
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      } else {
        // Yield-only pacing still gives a queued StopSignal a chance to
        // interleave, same shape as the real engine's `await Future(() {})`.
        await Future<void>(() {});
      }
      if (stopRequested()) break;
      emit(chunk);
      generated++;
    }

    final tailBlockMs = (script?['tailBlockMs'] as num?)?.toInt() ?? 0;
    if (tailBlockMs > 0) {
      _log('tail');
      sleep(Duration(milliseconds: tailBlockMs));
    }

    return GenAiGenerationStats(
      promptTokens: chunks.length,
      generatedTokens: generated,
      decodeMs: generated,
    );
  }

  @override
  int countTokens(String text) {
    _log('count');
    if (text.startsWith('block:')) {
      sleep(Duration(milliseconds: int.parse(text.substring(6))));
    }
    // Deterministic zero-native token count — good enough for lifecycle
    // assertions, which only care about the reply round-tripping.
    return (text.length / 4).ceil();
  }

  @override
  void resetGenerator() => _log('reset');

  @override
  void close() {
    _log('close');
    if (_config['throwOnClose'] == true) {
      throw StateError('fake GenAI close blew up');
    }
  }
}
