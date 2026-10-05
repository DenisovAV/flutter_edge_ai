import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'prompt_strategy.dart';

/// Wraps an `InferenceModel` to make single-shot translation a one-call
/// operation. Plugin owns the model lifecycle; the runner only owns the
/// per-call session.
class TranslateRunner {
  TranslateRunner({
    required InferenceModel model,
    required TranslationPromptStrategy strategy,
  }) : _model = model,
       _strategy = strategy;

  final InferenceModel _model;
  final TranslationPromptStrategy _strategy;

  // `topK: 1` → argmax (deterministic). Temperature stays > 0 because
  // some GPU sampler kernels divide by it.
  static const double _greedyTemperature = 0.8;
  static const int _greedyTopK = 1;

  /// One-shot translation: returns the full output string once decoding
  /// completes.
  Future<String> translate({
    required String text,
    required String src,
    required String dst,
  }) async {
    final session = await _model.createSession(
      temperature: _greedyTemperature,
      topK: _greedyTopK,
    );
    try {
      await session.addQueryChunk(
        Message.text(
          text: _strategy.formatPrompt(src: src, dst: dst, text: text),
          isUser: true,
        ),
      );
      return await session.getResponse();
    } finally {
      await _safeClose(session);
    }
  }

  /// Streaming translation: emits each generated chunk as the model decodes.
  /// Caller can cancel via the returned `Stream`'s subscription; the session
  /// is closed when the stream is done (either fully consumed or cancelled).
  Stream<String> translateStream({
    required String text,
    required String src,
    required String dst,
  }) async* {
    final session = await _model.createSession(
      temperature: _greedyTemperature,
      topK: _greedyTopK,
    );
    try {
      await session.addQueryChunk(
        Message.text(
          text: _strategy.formatPrompt(src: src, dst: dst, text: text),
          isUser: true,
        ),
      );
      yield* session.getResponseAsync();
    } finally {
      await _safeClose(session);
    }
  }

  // Don't let a session-close failure mask the original exception — Dart
  // `finally` would otherwise overwrite the in-flight error.
  Future<void> _safeClose(InferenceModelSession session) async {
    try {
      await session.close();
    } catch (e, st) {
      debugPrint('[TranslateRunner] session.close() failed: $e\n$st');
    }
  }
}
