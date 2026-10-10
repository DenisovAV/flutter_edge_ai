// ORT-GenAI `InferenceModel` — text-only v1 (hardened plan Phase 3, Task 2).
// Shape mirrors `FfiInferenceModel`
// (`flutter_edge_ai_litertlm/lib/src/ffi/ffi_inference_model.dart`)'s
// createSession singleton lane (issue #308 pattern), minus `openSession`
// (ORT-GenAI's one persistent generator per client is a v2 follow-on — the
// base `InferenceModel.openSession` UnsupportedError is inherited unchanged)
// and minus `createChat` (the base `InferenceModel.createChat`, which routes
// through `createSession`, is inherited unchanged too).
import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/tool.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';

import 'ffi/gen_ai_client.dart';
import 'onnx_session.dart';

/// An ORT-GenAI text model: one [GenAiClient] (and its worker isolate), one
/// session at a time.
///
/// It closes itself when its worker dies — an uncaught error, or the isolate
/// ended under it: it turns closed, runs [onClose] and fires its close
/// listeners, once, so core drops its cached model, and later calls fail with
/// the reason. [close] afterwards still releases the client and fires nothing
/// again.
class OnnxInferenceModel extends InferenceModel with CloseNotifier {
  OnnxInferenceModel({
    required this.client,
    required this.maxTokens,
    required this.modelType,
    required this.activeBackend,
    this.fileType = ModelFileType.onnx,
    required this.onClose,
  }) {
    // A worker that dies on its own turns this model closed and tells its
    // listeners, so core drops its cached model and the next `getActiveModel`
    // builds a fresh one — instead of handing out this one, whose every call
    // would fail.
    final died = unexpectedExitOf(client);
    if (died != null) unawaited(died.then(_onWorkerDied));
  }

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

  /// What every [close] after the first returns: completes, normally, once
  /// the one shared teardown is done — so a second caller waits for it
  /// instead of returning while it is still running.
  Future<void>? _closeFuture;

  /// Whether [onClose] and the close listeners have run; they run once,
  /// whether the model was closed or its worker died.
  bool _closeNotified = false;

  /// Why the worker died, when it did; later calls quote it.
  String? _deathReason;

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
      final death = _deathReason;
      throw StateError(
        death == null
            ? 'Model is closed. Create a new instance to use it again'
            : 'Model is closed because $death. Create a new instance to use '
                  'it again',
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
        final death = _deathReason;
        throw StateError(
          death == null
              ? 'Model was closed while creating a session'
              : 'Model was closed while creating a session, because $death',
        );
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

  /// Closes the session, then shuts the client down. Also after the worker
  /// died: the client's ports still need closing, and the close listeners —
  /// which the death already fired — do not fire again. Concurrent callers
  /// share one teardown.
  @override
  Future<void> close() {
    final teardownDone = _closeFuture;
    if (teardownDone != null) return teardownDone;
    final settled = Completer<void>();
    _closeFuture = settled.future;
    // `whenComplete` hands the first caller the teardown's own outcome — a
    // throwing `onClose` or listener included — while every later caller
    // gets `settled`, which only ever completes normally once it is done.
    return _close().whenComplete(settled.complete);
  }

  Future<void> _close() async {
    _isClosed = true;
    // Every step runs even when an earlier one threw: a throwing shutdown — a
    // custom GenAiClient's — must still reach the listeners core evicts on.
    // The first failure goes to the caller; a later one is printed, because
    // a `finally` that throws would replace the first and lose it.
    Object? firstError;
    StackTrace? firstStack;
    void fail(String step, Object error, StackTrace stack) {
      if (firstError == null) {
        firstError = error;
        firstStack = stack;
        return;
      }
      // `print`, not edgeAiLog, which is silent in release.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_onnx] WARNING: $step also failed while the ONNX '
        'model was closing: $error\n$stack',
      );
    }

    try {
      // OnnxSession.close() already stops+resets; this extra stop is
      // defense-in-depth for the (currently unreachable, but not worth
      // relying on) case of a live generation with no owning session.
      // Idempotent/cheap on the client and worker either way.
      await client.stopGeneration();
      await _session?.close();
    } catch (e, st) {
      fail('closing the session', e, st);
    }
    try {
      await client.shutdown();
    } catch (e, st) {
      fail('shutting the client down', e, st);
    }
    try {
      _notifyClosed();
    } catch (e, st) {
      fail('a close listener', e, st);
    }
    final error = firstError;
    if (error != null) Error.throwWithStackTrace(error, firstStack!);
  }

  void _notifyClosed() {
    if (_closeNotified) return;
    _closeNotified = true;
    try {
      onClose();
    } finally {
      // Even when `onClose` throws: core drops its cached instance on a close
      // listener, and one it never hears about is handed to every later
      // caller.
      fireCloseListeners();
    }
  }

  void _onWorkerDied(String reason) {
    _deathReason = reason;
    _isClosed = true;
    try {
      _notifyClosed();
    } catch (e, st) {
      // Nobody awaits this path, so a throwing listener would otherwise be an
      // unhandled error with no context; `print`, because edgeAiLog is silent
      // in release.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_onnx] WARNING: a close listener threw while an ONNX '
        'model whose worker had died was being closed: $e\n$st',
      );
    }
  }
}
