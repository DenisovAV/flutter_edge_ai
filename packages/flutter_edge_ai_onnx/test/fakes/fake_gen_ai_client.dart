// Fake GenAiClient — zero dlopen. Used by every unit test in this package
// that drives OnnxSession/OnnxInferenceModel/OnnxEngine without touching
// native ORT-GenAI (hardened plan Phase 3, Task 6).
import 'dart:async';

import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';

class FakeGenAiClient implements GenAiClient {
  FakeGenAiClient({this.chunksToEmit = const ['Hello', ' ', 'world']});

  final List<String> chunksToEmit;

  /// Every turn passed to [generate], in call order.
  final List<GenAiTurn> generateCalls = [];
  final List<String> countTokensCalls = [];
  int resetSessionCalls = 0;
  int shutdownCalls = 0;
  int stopGenerationCalls = 0;

  /// The session id of each [stopGeneration] / [resetSession] call, in order.
  final List<int?> stoppedSessions = [];
  final List<int?> resetSessions = [];
  final Map<int?, GenAiGenerationStats> _statsBySession = {};
  int loadCalls = 0;

  bool loaded = false;
  bool closed = false;
  String? loadedModelDir;
  int? loadedContextWindow;

  /// Set by the test to make [load] fail (simulates a dlopen/model-load
  /// error) — the real client's error path.
  Object? loadError;

  /// Set by the test to make [generate] fail instead of streaming.
  Object? generateError;

  /// Set by the test to make [shutdown] throw — a custom [GenAiClient]
  /// whose teardown fails.
  Object? shutdownError;

  bool _stopRequested = false;

  @override
  GenAiGenerationStats? get lastGenerationStats => _statsBySession[null];

  set lastGenerationStats(GenAiGenerationStats? value) {
    if (value == null) {
      _statsBySession.remove(null);
    } else {
      _statsBySession[null] = value;
    }
  }

  @override
  GenAiGenerationStats? generationStatsOf(int? sessionId) =>
      _statsBySession[sessionId];

  @override
  Future<void> load(String modelDir, {int contextWindow = 1024}) async {
    loadCalls++;
    if (loadError case final e?) throw e;
    loaded = true;
    loadedModelDir = modelDir;
    loadedContextWindow = contextWindow;
  }

  @override
  Stream<String> generate(GenAiTurn turn) {
    generateCalls.add(turn);
    // A fresh turn always starts with a clear stop flag — mirrors the real
    // worker's `runGenerate` resetting `stopRequested` at the top.
    _stopRequested = false;
    final controller = StreamController<String>();
    unawaited(() async {
      if (generateError case final e?) {
        controller.addError(e);
        await controller.close();
        return;
      }
      var emitted = 0;
      for (final chunk in chunksToEmit) {
        if (_stopRequested) break;
        controller.add(chunk);
        emitted++;
        // Yield so a test-driven stopGeneration() between chunks can land.
        await Future<void>.delayed(Duration.zero);
      }
      _statsBySession[turn.sessionId] = GenAiGenerationStats(
        promptTokens: (turn.userContent.length / 4).ceil(),
        generatedTokens: emitted,
        decodeMs: emitted,
      );
      await controller.close();
    }());
    return controller.stream;
  }

  @override
  Future<int> countTokens(String text) async {
    countTokensCalls.add(text);
    return (text.length / 4).ceil();
  }

  @override
  Future<void> stopGeneration({int? sessionId}) async {
    stopGenerationCalls++;
    stoppedSessions.add(sessionId);
    _stopRequested = true;
  }

  @override
  Future<void> resetSession({int? sessionId}) async {
    resetSessionCalls++;
    resetSessions.add(sessionId);
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    closed = true;
    final error = shutdownError;
    if (error != null) throw error;
  }
}
