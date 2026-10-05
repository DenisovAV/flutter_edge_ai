// Fake GenAiClient — zero dlopen. Used by every unit test in this package
// that drives OnnxSession/OnnxInferenceModel/OnnxEngine without touching
// native ORT-GenAI (hardened plan Phase 3, Task 6).
import 'dart:async';

import 'package:flutter_gemma_onnx/src/ffi/gen_ai_client.dart';

class FakeGenAiClient implements GenAiClient {
  FakeGenAiClient({this.chunksToEmit = const ['Hello', ' ', 'world']});

  final List<String> chunksToEmit;

  /// Every turn passed to [generate], in call order.
  final List<GenAiTurn> generateCalls = [];
  final List<String> countTokensCalls = [];
  int resetSessionCalls = 0;
  int shutdownCalls = 0;
  int stopGenerationCalls = 0;
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

  bool _stopRequested = false;

  @override
  GenAiGenerationStats? lastGenerationStats;

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
      lastGenerationStats = GenAiGenerationStats(
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
  Future<void> stopGeneration() async {
    stopGenerationCalls++;
    _stopRequested = true;
  }

  @override
  Future<void> resetSession() async {
    resetSessionCalls++;
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    closed = true;
  }
}
