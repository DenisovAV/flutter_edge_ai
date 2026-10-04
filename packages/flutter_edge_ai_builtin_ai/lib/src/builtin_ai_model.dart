import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/core/chat.dart'
    show InferenceChat, defaultMaxFunctionBufferLength;
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart'
    show CloseNotifier;
import 'package:flutter_edge_ai/core/model.dart' show ModelFileType, ModelType;
import 'package:flutter_edge_ai/core/tool.dart' show Tool, ToolChoice;
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart' show edgeAiLog;
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show InferenceModel, InferenceModelSession;
import 'package:flutter_local_ai/flutter_local_ai.dart'
    show LocalAi, LocalAiModel;
import 'package:meta/meta.dart' show experimental;

import 'builtin_ai_session.dart';

/// One-time guard so requesting thinking mode logs a single warning rather
/// than spamming one per session/chat. Built-in OS models expose no thinking
/// control, so the flag is accepted (for API parity) and ignored.
bool _thinkingUnsupportedWarned = false;

@visibleForTesting
void resetThinkingUnsupportedWarning() => _thinkingUnsupportedWarned = false;

void _warnThinkingIgnoredOnce() {
  if (_thinkingUnsupportedWarned) return;
  _thinkingUnsupportedWarned = true;
  edgeAiLog(
    '[BuiltInAI] Thinking mode is not supported by built-in OS models '
    '(Gemini Nano / Apple Foundation Models); the flag is ignored.',
  );
}

/// A loaded OS built-in model, adapting flutter_local_ai's [LocalAiModel] to
/// flutter_edge_ai's [InferenceModel].
///
/// The OS owns the weights, so this is a session factory rather than anything
/// holding a checkpoint. It supports both flutter_edge_ai session lanes:
/// [createSession] keeps the singleton [session] field (replacing and closing
/// any previous one), while [openSession] returns detached sessions for
/// concurrent conversations. Mixes [CloseNotifier] so core can reset its
/// singleton bookkeeping on close.
class BuiltInAiModel extends InferenceModel with CloseNotifier {
  BuiltInAiModel({
    required this._model,
    required this.modelType,
    required this.maxTokens,
    required this.supportImage,
    this.fileType = ModelFileType.builtIn,
    this.systemInstruction,
    this.maxNumImages,
    this.maxConcurrentSessions,
  });

  final LocalAiModel _model;
  final ModelType modelType;
  final bool supportImage;
  final String? systemInstruction;
  final int? maxNumImages;
  final int? maxConcurrentSessions;
  int _openingSessions = 0;
  Future<void> _singletonTail = Future.value();

  @override
  final ModelFileType fileType;

  @override
  final int maxTokens;

  /// The OS chooses its own accelerator and does not report which; claiming one
  /// would be a guess.
  @override
  PreferredBackend? get activeBackend => null;

  /// The underlying flutter_local_ai model.
  ///
  /// This is the supported escape hatch for the capabilities flutter_edge_ai's
  /// [InferenceModel] has no slot for — native tool calling and
  /// schema-constrained output. Open a `LocalAiSession` from it (or reach one
  /// through [BuiltInAiSession.localAiSession]) and drive flutter_local_ai's
  /// own API directly; the two APIs share one host, so sessions opened either
  /// way coexist.
  ///
  /// Experimental: this is a `flutter_local_ai` type, so it may change with
  /// that package's next major release independently of this one.
  @experimental
  LocalAiModel get localAiModel => _model;

  bool _isClosed = false;
  BuiltInAiSession? _session;
  final List<BuiltInAiSession> _openSessions = [];

  @override
  InferenceModelSession? get session => _session;

  @override
  List<InferenceModelSession> get sessions =>
      List.unmodifiable([?_session, ..._openSessions]);

  Future<BuiltInAiSession> _newSession({
    required double temperature,
    required int topK,
    required double? topP,
    required bool? enableVisionModality,
    required bool? enableAudioModality,
    required String? systemInstruction,
    required bool enableThinking,
    required int? maxOutputTokens,
    required void Function(BuiltInAiSession session) onClose,
  }) async {
    if (_isClosed) {
      throw StateError(
        'Model is closed. Create a new instance to use it again',
      );
    }
    if (enableAudioModality == true) {
      throw UnsupportedError('Audio is not supported by built-in OS models');
    }
    if (enableThinking) _warnThinkingIgnoredOnce();

    final vision = enableVisionModality ?? supportImage;
    if (maxConcurrentSessions != null &&
        _model.sessions.length + _openingSessions >= maxConcurrentSessions!) {
      throw StateError(
        'Maximum concurrent sessions reached ($maxConcurrentSessions).',
      );
    }
    _openingSessions++;
    try {
      // Vision is refused at configuration time, not at the first image: an
      // explicit `enableVisionModality: true` the backend cannot honour is a
      // mistake, and a session that quietly is not the one that was asked for
      // fails later and further from the cause.
      if (vision && !(await LocalAi.capabilities()).supportsVision) {
        throw UnsupportedError('This backend does not support image input.');
      }
      // `tools` is deliberately NOT forwarded to flutter_local_ai's native
      // tool API below. flutter_edge_ai's InferenceChat owns function calling:
      // it weaves the declarations into the prompt and parses the calls back
      // out, and the app executes them. Handing the same tools to the native
      // runner as well would produce two competing tool loops for one turn.
      // Native tool calling stays reachable through `localAiModel` /
      // `BuiltInAiSession.localAiSession`.
      final inner = await _model.openSession(
        temperature: temperature,
        topK: topK,
        topP: topP,
        maxOutputTokens: maxOutputTokens,
        systemInstruction: systemInstruction ?? this.systemInstruction,
      );

      if (_isClosed) {
        await inner.close();
        throw StateError('Model closed while the session was opening.');
      }
      late final BuiltInAiSession created;
      created = BuiltInAiSession(
        session: inner,
        modelType: modelType,
        fileType: fileType,
        supportImage: vision,
        maxNumImages: maxNumImages,
        onClose: () => onClose(created),
      );
      return created;
    } finally {
      _openingSessions--;
    }
  }

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
    final previousCreation = _singletonTail;
    final completed = Completer<void>();
    _singletonTail = completed.future;
    await previousCreation;
    try {
      if (loraPath != null) {
        throw UnsupportedError('LoRA is not exposed by this engine.');
      }
      // The singleton lane: a new session replaces the previous one, whose
      // native context must be released first.
      final previous = _session;
      if (previous != null) await previous.close();

      final created = await _newSession(
        temperature: temperature,
        topK: topK,
        topP: topP,
        enableVisionModality: enableVisionModality,
        enableAudioModality: enableAudioModality,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        maxOutputTokens: maxOutputTokens,
        // Identity-guarded: a late close of a superseded session must not null
        // out a newer one.
        onClose: (session) {
          if (identical(_session, session)) _session = null;
        },
      );
      _session = created;
      return created;
    } finally {
      completed.complete();
    }
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
    if (loraPath != null) {
      throw UnsupportedError('LoRA is not exposed by this engine.');
    }
    final created = await _newSession(
      temperature: temperature,
      topK: topK,
      topP: topP,
      enableVisionModality: enableVisionModality,
      enableAudioModality: enableAudioModality,
      systemInstruction: systemInstruction,
      enableThinking: enableThinking,
      maxOutputTokens: maxOutputTokens,
      onClose: _openSessions.remove,
    );
    _openSessions.add(created);
    return created;
  }

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
    if (supportAudio == true) {
      throw UnsupportedError('Audio is not supported by built-in OS models');
    }
    chat = InferenceChat(
      sessionCreator: () => createSession(
        temperature: temperature,
        randomSeed: randomSeed,
        topK: topK,
        topP: topP,
        loraPath: loraPath,
        enableVisionModality: supportImage ?? this.supportImage,
        systemInstruction: systemInstruction ?? this.systemInstruction,
        enableThinking: isThinking,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
      ),
      maxTokens: maxTokens,
      tokenBuffer: tokenBuffer,
      supportImage: supportImage ?? this.supportImage,
      supportAudio: false,
      supportsFunctionCalls: supportsFunctionCalls ?? false,
      maxFunctionBufferLength:
          maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
      tools: tools,
      modelType: modelType ?? this.modelType,
      isThinking: isThinking,
      fileType: fileType,
      toolChoice: toolChoice,
      systemInstruction: systemInstruction ?? this.systemInstruction,
    );
    await chat!.initSession();
    return chat!;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    // Release the model and reset core's singleton bookkeeping even if a
    // session's close throws — otherwise a phantom model lingers in the
    // registry with the OS resource leaked.
    try {
      _session = null;
      _openSessions.clear();
    } finally {
      fireCloseListeners();
      await _model.close();
    }
  }
}
