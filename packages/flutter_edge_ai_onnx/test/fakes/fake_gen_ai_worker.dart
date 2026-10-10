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
// A call that must be held — a native call that has not returned yet —
// blocks on a gate: it waits, without yielding, until the file
// `<log>.release` exists. The test creates that file when it is ready, so the
// order of events is fixed by the test, not by how fast the machine is. A
// gate gives up on its own after 30 s, so a failing test never leaves a
// worker blocked for good.
//
// Engine configuration — the `modelDir` passed to `GenAiFfiClient.load` —
// is JSON when the test needs it (anything else means the defaults):
//   {"log": "/tmp/x.log", "failLoad": true, "throwOnClose": true}
// - `log`: the engine appends one line per call (`load`, `generate`,
//   `count`, `reset`, `close`, and `tail` for a turn's last call) to this
//   file — the only way the test, on the main isolate, can see what ran
//   inside the worker. The writes are synchronous and flushed, so a line is
//   on disk before the call returns. Gates use `<log>.release`.
// - `failLoad`: `load` throws after it "allocated" something.
// - `gateLoad`: `load` blocks on the gate.
// - `gateClose`: `close` blocks on the gate before it logs.
// - `throwOnClose`: `close` throws.
// - `gateReset`: `resetGenerator` logs, then blocks on the gate.
// - `throwOnReset`: `resetGenerator` throws.
// - `killOnReset`: `resetGenerator` kills the isolate.
// - `dieAfterMs`: the isolate kills itself this long after load, with nothing
//   in flight — a worker that dies while idle.
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
// - `gate`: blocks on the gate before the first chunk — a prompt's prefill,
//   one native call nothing can interrupt.
// - `gateAtTail`: once the chunks are done, logs `tail` and blocks on the
//   gate before the turn returns — a last native call, during which the test
//   sends what it wants queued behind the turn.
// - `untilStopped`: after the chunks, yields until a stop is requested (30 s
//   at most), so the turn ends only when something stops it.
// - `kill`: when true, the isolate kills ITSELF (`Isolate.current.kill`)
//   instead of ever replying — simulates an unexpected native crash
//   mid-generation, same shape as `embedding_worker_test.dart`'s
//   `killMidRequest` fake mode. Never sends a Chunk/GenerateDone.
// - `crash`: when true, an uncaught error takes the isolate down at the
//   turn's first yield — a death mid-turn that reports its reason.
// - `throw`: when true, the turn throws — a native call that failed.
// - `throwUnprintable`: the turn throws an error whose `toString` throws, so
//   serving it fails and the serving loop itself throws.
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

/// An error whose `toString` throws: serving it as a reply throws too.
class _UnprintableError {
  @override
  String toString() =>
      throw StateError('fake error that cannot describe itself');
}

class _ScriptedEngine implements GenAiWorkerEngine {
  _ScriptedEngine(String modelDir) : _config = _objectOrNull(modelDir) ?? {};

  final Map<String, dynamic> _config;

  String? get _logPath => _config['log'] as String?;

  void _log(String line) {
    final path = _logPath;
    if (path == null) return;
    File(path).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  /// Blocks this isolate — no events, no microtasks — until the test creates
  /// `<log>.release`, the way a synchronous native call does.
  void _blockUntilReleased() {
    final release = File('$_logPath.release');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!release.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('fake gate was never released');
      }
      sleep(const Duration(milliseconds: 5));
    }
  }

  @override
  Future<void> load() async {
    _log('load');
    if (_config['failLoad'] == true) {
      throw StateError('fake GenAI engine refused to load');
    }
    if (_config['gateLoad'] == true) _blockUntilReleased();
    final dieAfterMs = _config['dieAfterMs'];
    if (dieAfterMs is num) {
      Timer(
        Duration(milliseconds: dieAfterMs.toInt()),
        () => Isolate.current.kill(priority: Isolate.immediate),
      );
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

    if (script?['gate'] == true) _blockUntilReleased();
    if (script?['throw'] == true) {
      throw StateError('fake generation failed');
    }
    if (script?['throwUnprintable'] == true) throw _UnprintableError();
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

    if (script?['untilStopped'] == true) {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!stopRequested() && DateTime.now().isBefore(deadline)) {
        await Future<void>(() {});
      }
    }

    if (script?['gateAtTail'] == true) {
      _log('tail');
      _blockUntilReleased();
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
    // Deterministic zero-native token count — good enough for lifecycle
    // assertions, which only care about the reply round-tripping.
    return (text.length / 4).ceil();
  }

  @override
  void resetGenerator() {
    _log('reset');
    if (_config['gateReset'] == true) _blockUntilReleased();
    if (_config['killOnReset'] == true) {
      Isolate.current.kill(priority: Isolate.immediate);
    }
    if (_config['throwOnReset'] == true) {
      throw StateError('fake generator reset blew up');
    }
  }

  @override
  void close() {
    if (_config['gateClose'] == true) _blockUntilReleased();
    _log('close');
    if (_config['throwOnClose'] == true) {
      throw StateError('fake GenAI close blew up');
    }
  }
}
