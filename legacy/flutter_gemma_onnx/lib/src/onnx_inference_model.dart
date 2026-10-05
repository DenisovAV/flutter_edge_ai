// ORT-GenAI `InferenceModel` — text-only v1 (hardened plan Phase 3, Task 2).
// Shape mirrors `FfiInferenceModel`
// (`flutter_gemma_litertlm/lib/src/ffi/ffi_inference_model.dart`)'s
// createSession singleton lane (issue #308 pattern), minus `openSession`
// (ORT-GenAI's one persistent generator per client is a v2 follow-on — the
// base `InferenceModel.openSession` UnsupportedError is inherited unchanged)
// and minus `createChat` (the base `InferenceModel.createChat`, which routes
// through `createSession`, is inherited unchanged too).
import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/core/tool.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart';

import 'ffi/gen_ai_client.dart';
import 'onnx_session.dart';

class OnnxInferenceModel extends InferenceModel with CloseNotifier {
  OnnxInferenceModel({
    required this.client,
    required this.maxTokens,
    required this.modelType,
    required this.activeBackend,
    this.fileType = ModelFileType.onnx,
    required this.onClose,
  });

  final GenAiClient client;
  final ModelType modelType;

  @override
  final ModelFileType fileType;

  @override
  final int maxTokens;

  @override
  final PreferredBackend? activeBackend;

  /// Legacy hook fired alongside [CloseNotifier.fireCloseListeners] — the
  /// engine passes a no-op; core registers its singleton-reset via
  /// [addCloseListener] instead (same split as `FfiInferenceModel`).
  final VoidCallback onClose;

  OnnxSession? _session;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  @override
  InferenceModelSession? get session => _session;

  @override
  Future<InferenceModelSession> createSession({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    String? loraPath,
    bool? enableVisionModality,
    bool? enableAudioModality,
    String? systemInstruction,
    bool enableThinking = false,
    List<Tool> tools = const [],
    int? maxOutputTokens,
  }) async {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    if (loraPath != null) {
      throw UnsupportedError(
        'LoRA weights are not supported on the ONNX GenAI path '
        '(loraPath=$loraPath). Use a MediaPipe .task model instead.',
      );
    }
    if (enableVisionModality == true || enableAudioModality == true) {
      throw UnsupportedError(
        'Vision/audio modalities are not supported on the ONNX GenAI '
        'session (v1, text-only). Use a MediaPipe .task or .litertlm model.',
      );
    }

    // Single-flight guard for concurrent callers; sequential calls fall
    // through and close the previous session before opening a fresh one —
    // same rationale as `FfiInferenceModel.createSession` (issue #308).
    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<InferenceModelSession>();

    try {
      // Legacy singleton lane: close the previous session (and, via its
      // close(), reset the client's live generator) BEFORE opening a fresh
      // one, so a new session never inherits stale KV-cache history.
      await _session?.close();

      if (_isClosed) {
        throw StateError('Model was closed while creating a session');
      }

      late final OnnxSession newSession;
      newSession = OnnxSession(
        client: client,
        modelType: modelType,
        fileType: fileType,
        systemInstruction: systemInstruction,
        maxOutputTokens: maxOutputTokens,
        // Identity-guarded so a late close of a superseded session can't
        // null a newer `_session` (mirrors `FfiInferenceModel`).
        onClose: () {
          if (identical(_session, newSession)) _session = null;
        },
      );
      _session = newSession;
      completer.complete(newSession);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _createCompleter = null;
    }
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      // OnnxSession.close() already stops+resets; this extra stop is
      // defense-in-depth for the (currently unreachable, but not worth
      // relying on) case of a live generation with no owning session.
      // Idempotent/cheap on the client and worker either way.
      await client.stopGeneration();
      await _session?.close();
    } finally {
      await client.shutdown();
      onClose();
      fireCloseListeners();
    }
  }
}
