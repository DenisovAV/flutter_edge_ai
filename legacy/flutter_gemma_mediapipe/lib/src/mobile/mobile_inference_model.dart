import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';

import 'package:flutter_gemma/core/chat.dart';
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/core/tool.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show InferenceModel, InferenceModelSession;

// MobileInferenceModel exposes `activeBackend` as part of the [InferenceModel]
// contract, whose type is core's PreferredBackend (from package:flutter_gemma).
// The MediaPipe→core enum bridge lives in the engine; this model stores core's
// value type directly so the override is valid and core's type never tangles
// with the package's own pigeon enum.
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;

import 'mobile_inference_session.dart';

class MobileInferenceModel extends InferenceModel with CloseNotifier {
  MobileInferenceModel({
    required this.maxTokens,
    required this.onClose,
    required this.modelType,
    this.fileType = ModelFileType.task,
    this.preferredBackend,
    this.activeBackend,
    this.supportedLoraRanks,
    this.supportImage = false, // Enabling image support
    this.supportAudio = false, // Enabling audio support (Gemma 3n E4B)
    this.maxNumImages,
    this.maxConcurrentSessions,
  });

  final ModelType modelType;
  @override
  final ModelFileType fileType;
  @override
  Future<InferenceChat> createChat({
    double temperature = .8,
    int randomSeed = 1,
    int topK = 1,
    double? topP,
    int tokenBuffer = 256,
    String? loraPath,
    bool? supportImage,
    bool? supportAudio,
    List<Tool> tools = const [],
    bool? supportsFunctionCalls,
    bool isThinking = false,
    ModelType? modelType,
    ToolChoice toolChoice = ToolChoice.auto,
    int? maxFunctionBufferLength,
    String? systemInstruction,
    int? maxOutputTokens,
  }) async {
    chat = InferenceChat(
      sessionCreator: () => createSession(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage ?? false,
        enableAudioModality: supportAudio ?? this.supportAudio,
        systemInstruction: systemInstruction,
        enableThinking: isThinking,
        maxOutputTokens: maxOutputTokens,
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? false,
      supportAudio: supportAudio ?? this.supportAudio,
      supportsFunctionCalls: supportsFunctionCalls ?? false,
      maxFunctionBufferLength:
          maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
      tools: tools,
      modelType: modelType ?? this.modelType,
      isThinking: isThinking,
      fileType: fileType,
      toolChoice: toolChoice,
      systemInstruction: systemInstruction,
    );
    await chat!.initSession();
    return chat!;
  }

  @override
  final int maxTokens;
  @override
  final PreferredBackend? activeBackend;
  final VoidCallback onClose;
  final PreferredBackend? preferredBackend;
  final List<int>? supportedLoraRanks;
  final bool supportImage;
  final bool supportAudio;
  final int? maxNumImages;

  /// Cap on concurrent [openSession] sessions; null = unlimited. Wired for
  /// when the MediaPipe ProxyApi multi-session path lands; today
  /// [openSession] on the MediaPipe `.task` path throws UnsupportedError.
  final int? maxConcurrentSessions;

  bool _isClosed = false;
  MobileInferenceModelSession? _session;
  Completer<InferenceModelSession>? _createCompleter;

  /// Concurrent sessions opened via [openSession] — detached from the legacy
  /// [_session] singleton. Each owns one native `LlmInferenceSession`.
  final Set<MultiSessionMobileInferenceModelSession> _openSessions = {};

  /// Monotonic session-id generator. Starts at 1; the legacy singleton path
  /// carries no `sessionId` so there is no collision with these ids.
  int _nextSessionId = 1;

  /// Serializes generation across all open sessions — concurrent contexts,
  /// serialized inference (same model as the .litertlm FFI path). Avoids
  /// mobile OOM from parallel generations and keeps the shared event channel
  /// unambiguous.
  final Mutex _generationMutex = Mutex();

  @override
  InferenceModelSession? get session => _session;

  @override
  List<InferenceModelSession> get sessions =>
      List.unmodifiable([if (_session != null) _session!, ..._openSessions]);

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
    List<Tool> tools =
        const [], // MediaPipe path: tools handled via chat.dart prompt
    int? maxOutputTokens,
  }) async {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    if (maxOutputTokens != null) {
      // MediaPipe's `maxTokens` is a single total (input + output) set at
      // model creation; LlmInferenceSessionOptions has no per-session output
      // cap. Honor the call but make the limitation explicit.
      gemmaLog(
        '[MediaPipe] maxOutputTokens ($maxOutputTokens) is not supported on '
        'the .task path (no session-level output cap); ignoring. Use a smaller '
        'maxTokens on createModel, or the .litertlm engine, to bound output.',
      );
    }
    // Single-flight guard for genuinely *concurrent* callers only. Unlike
    // the model singleton, a session is NOT reused across calls: each
    // createSession (and therefore each createChat) must yield a fresh
    // native session with a clean KV cache. The completer is cleared in
    // the `finally` below once creation settles, so a *sequential* second
    // call falls through to the native createSession — which closes the
    // prior session and creates a new one (FlutterGemmaPlugin.createSession
    // does `session?.close(); session = engine.createSession(...)`) —
    // instead of returning the stale wrapper. Without this, the cached
    // completer made every later createChat reuse the first session, so
    // the previous conversation's KV cache bled into the next chat (the
    // app sends a clean prompt; the model still conditions on the old
    // context). See https://github.com/DenisovAV/flutter_gemma/issues/308.
    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<InferenceModelSession>();
    try {
      // Close any prior singleton session before creating the next so its
      // Dart-side resources (event subscription, stream controller) are
      // released and stray calls on the old wrapper throw `Model is
      // closed` cleanly instead of silently hitting the new native
      // session. The native layer also closes the old session, but doing
      // it here keeps the orphaned wrapper's `_isClosed` flag honest and
      // means at most one live wrapper maps to the single native session.
      if (_session case final previous?) {
        await previous.close();
      }

      // LoRA support is fully integrated via Modern API (InferenceInstallationBuilder)
      final resolvedLoraPath = loraPath;

      await platformService.createSession(
        randomSeed: randomSeed,
        temperature: temperature,
        topK: topK,
        topP: topP,
        loraPath: resolvedLoraPath,
        // Enable vision modality if the model supports it
        enableVisionModality: enableVisionModality ?? supportImage,
        // Enable audio modality if the model supports it (Gemma 3n E4B)
        enableAudioModality: enableAudioModality ?? supportAudio,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
      );

      late final MobileInferenceModelSession session;
      session = MobileInferenceModelSession(
        modelType: modelType,
        fileType: fileType,
        supportImage: enableVisionModality ?? supportImage,
        supportAudio: enableAudioModality ?? supportAudio,
        systemInstruction: systemInstruction,
        // Identity-guarded so a late close of a superseded session can't
        // null a newer `_session`. Does NOT touch `_createCompleter` —
        // that is owned by the `finally` below, not by session teardown.
        onClose: () {
          if (identical(_session, session)) _session = null;
        },
      );
      _session = session;
      completer.complete(session);
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      // Pure in-flight guard: clear once creation settles (success OR
      // failure). Previously the completer was only cleared from the
      // onClose, which (a) made it a permanent cache across createChat
      // calls — the issue #308 KV-cache bleed — and (b) left a failed
      // creation permanently caching a rejected future, blocking retry
      // (the same class as the model-level issue #170 fix).
      _createCompleter = null;
    }
    // Returning `completer.future` (rather than the session / a rethrow)
    // keeps the caller as the error listener even after the completer is
    // cleared above, and mirrors the createModel idiom (issue #170). A
    // concurrent caller that hit the early `return completer.future`
    // shares this exact future, so success and failure both fan out to
    // every in-flight caller.
    return completer.future;
  }

  @override
  Future<InferenceModelSession> openSession({
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
    final cap = maxConcurrentSessions;
    if (cap != null && _openSessions.length >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one.',
      );
    }

    final id = _nextSessionId++;
    // MediaPipe holds N real LlmInferenceSession per engine — each call creates
    // an independent native session with its own KV cache. No singleton
    // overwrite; generation is serialized via [_generationMutex] on the
    // session objects, not here.
    await platformService.createSessionForId(
      sessionId: id,
      randomSeed: randomSeed,
      temperature: temperature,
      topK: topK,
      topP: topP,
      loraPath: loraPath,
      enableVisionModality: enableVisionModality ?? supportImage,
      enableAudioModality: enableAudioModality ?? supportAudio,
      systemInstruction: systemInstruction,
      enableThinking: enableThinking,
    );

    late final MultiSessionMobileInferenceModelSession session;
    session = MultiSessionMobileInferenceModelSession(
      sessionId: id,
      modelType: modelType,
      fileType: fileType,
      supportImage: enableVisionModality ?? supportImage,
      supportAudio: enableAudioModality ?? supportAudio,
      systemInstruction: systemInstruction,
      generationMutex: _generationMutex,
      onClose: () => _openSessions.remove(session),
    );
    _openSessions.add(session);
    return session;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    await _session?.close();
    // Copy because close() mutates _openSessions via the onClose callback.
    for (final s in _openSessions.toList()) {
      await s.close();
    }
    _openSessions.clear();
    onClose();
    fireCloseListeners();
    await platformService.closeModel();
  }
}
