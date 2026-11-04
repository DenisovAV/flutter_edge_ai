// Standalone library: the MediaPipe-web inference model, extracted from core's
// `flutter_edge_ai_web.dart`. Consumes the shared public web infra that STAYS in
// core (the web model sources from `engine_web.dart`, `detectImageMimeType`
// from `engine.dart`) plus the sibling MediaPipe JS interop
// (`llm_inference_web.dart`). The session and its prompt parts live in
// `web_model_session.dart` and `web_prompt.dart`.
import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';

import '../mediapipe_sampling.dart';
import 'llm_inference_backend.dart';
import 'llm_inference_web.dart';
import 'task_chat_format.dart';
import 'web_chat_template.dart';
import 'web_file_prefix.dart';
import 'web_model_session.dart';
import 'web_prompt.dart';

export 'web_model_session.dart' show WebModelSession;
export 'web_prompt.dart'
    show AudioPromptPart, ImagePromptPart, PromptPart, TextPromptPart;

/// Whether the "topP is ignored" warning was printed in this isolate.
bool _topPIgnoredWarned = false;

class WebInferenceModel extends InferenceModel with CloseNotifier {
  final VoidCallback onClose;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;
  @override
  final int maxTokens;

  final ModelType modelType;
  @override
  final ModelFileType fileType;
  @override
  PreferredBackend? get activeBackend => null;
  final List<int>? loraRanks;
  final WebModelSourceResolver sourceResolver;
  final bool supportImage; // Enabling image support
  final bool supportAudio; // Enabling audio support (Gemma 3n E4B)
  final int? maxNumImages;

  /// The loaded model. It belongs to the model, not to a session: each
  /// [createSession] starts a new conversation on it.
  Future<LlmInference>? _llmFuture;

  /// One per loaded model: it knows when the last call has ended, which a
  /// session that comes after a stopped one must wait for.
  LlmInferenceBackend? _backend;

  /// The chat format the loaded file declares, or the one its [modelType]
  /// implies; null when neither is known.
  WebChatTemplate? _template;
  @override
  InferenceModelSession? session;

  WebInferenceModel({
    required this.modelType,
    this.fileType = ModelFileType.task,
    required this.onClose,
    required this.maxTokens,
    this.loraRanks,
    required this.sourceResolver,
    this.supportImage = false,
    this.supportAudio = false,
    this.maxNumImages,
    this.maxConcurrentSessions,
  });

  /// Cap on the sessions open at once through [openSession]; null =
  /// unlimited. The legacy [session] does not count.
  final int? maxConcurrentSessions;

  /// The sessions [openSession] opened and nobody has closed yet.
  final Set<WebModelSession> _openSessions = {};

  /// Open sessions still waiting for the model to load: they count against
  /// [maxConcurrentSessions] from the check on, so two calls that overlap
  /// cannot both pass it.
  int _openingSessions = 0;

  @override
  List<InferenceModelSession> get engineSessions => [
    ?session,
    ..._openSessions,
  ];

  /// [openChat]'s unset model type, image and audio support are this
  /// model's own (D8); the rest keeps core's defaults.
  @override
  ResolvedChatRequest resolveChatRequest(ChatRequest request) =>
      ResolvedChatRequest(
        modelType: request.modelType ?? modelType,
        supportImage: request.supportImage ?? supportImage,
        supportAudio: request.supportAudio ?? supportAudio,
        supportsFunctionCalls: request.supportsFunctionCalls ?? false,
        tools: request.tools,
        maxFunctionBufferLength:
            request.maxFunctionBufferLength ?? defaultMaxFunctionBufferLength,
        temperature: request.temperature,
        randomSeed: request.randomSeed,
        topK: request.topK,
        topP: request.topP,
        tokenBuffer: request.tokenBuffer,
        loraPath: request.loraPath,
        enableThinking: request.enableThinking,
        toolChoice: request.toolChoice,
        systemInstruction: request.systemInstruction,
        maxOutputTokens: request.maxOutputTokens,
      );

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
    double? topP,
    String? loraPath,
    bool? enableVisionModality, // Enabling vision modality support
    bool? enableAudioModality, // Enabling audio modality support (Gemma 3n E4B)
    String? systemInstruction,
    bool enableThinking = false, // Not supported on Web (MediaPipe)
    List<Tool> tools =
        const [], // Tools wired through chat.dart prompt; SDK tools_json N/A on web
    int? maxOutputTokens,
  }) async {
    final sampling = _sessionSampling(
      temperature: temperature,
      randomSeed: randomSeed,
      topK: topK,
      topP: topP,
      enableVisionModality: enableVisionModality,
      enableAudioModality: enableAudioModality,
      enableThinking: enableThinking,
      maxOutputTokens: maxOutputTokens,
    );

    // One call at a time from here on. Two calls that arrive during the first
    // load both continue when it ends; the second would close the session the
    // first is about to return.
    final turn = _sessionLane;
    final done = Completer<void>();
    _sessionLane = done.future;
    try {
      await turn;
      // Closed before this call's turn came: a load now would build a new
      // LlmInference that nothing ever closes.
      _requireOpen();
      final llm = await _loadModel(
        sampling,
        loraPath,
        explicit: temperature != null || topK != null || randomSeed != null,
      );
      // Closed while it loaded: close() has already released what it had, so
      // a session built now would sit on a model that is gone.
      if (_isClosed) {
        throw StateError('The model was closed while it was loading.');
      }

      // Like the mobile model: a new session closes the one before it and
      // starts a clean conversation. MediaPipe web keeps nothing between
      // calls, so the conversation lives in the session, and a session that
      // outlived its chat would carry that chat into the next one.
      if (session case final previous?) {
        await previous.close();
        // Closed while the previous session closed: close() has already let
        // go of the backend, so a session now would outlive the model.
        _requireOpen();
      }
      late final WebModelSession created;
      created = _newSession(
        llm,
        systemInstruction: systemInstruction,
        onClose: () {
          // A closed session leaves [sessions]; a later one is not touched.
          if (identical(session, created)) session = null;
          onClose();
        },
      );
      return session = created;
    } finally {
      done.complete();
    }
  }

  /// The arguments of a new session: warns about the ones the web path
  /// ignores, and resolves the sampling, which throws for values it rejects.
  ResolvedSampling _sessionSampling({
    required double? temperature,
    required int? randomSeed,
    required int? topK,
    required double? topP,
    required bool? enableVisionModality,
    required bool? enableAudioModality,
    required bool enableThinking,
    required int? maxOutputTokens,
  }) {
    // Thinking mode not supported on Web (MediaPipe has no extraContext/channels API)
    if (enableThinking) {
      if (kDebugMode) {
        edgeAiLog(
          'Warning: enableThinking is not supported on Web (MediaPipe). '
          'Use Android or Desktop with .litertlm models for Gemma 4 thinking mode.',
        );
      }
    }
    if (maxOutputTokens != null) {
      edgeAiLog(
        '[MediaPipe Web] maxOutputTokens ($maxOutputTokens) is not supported '
        'on the .task web path (no session-level output cap); ignoring.',
      );
    }

    // Web images work, but through the model's supportImage, which sets
    // maxNumImages on the LlmInference below; enableVisionModality does not
    // turn them on. An image sent to a model created without supportImage
    // throws ArgumentError in addQueryChunk.
    if (enableVisionModality == true && !supportImage) {
      if (kDebugMode) {
        edgeAiLog(
          '[MediaPipe Web] Warning: vision modality requested, but the model '
          'was created without supportImage: true; an image message will '
          'throw ArgumentError.',
        );
      }
    }

    // Audio modality is handled via supportAudio flag in the model
    if (enableAudioModality == true && !supportAudio) {
      if (kDebugMode) {
        edgeAiLog(
          'Warning: Audio modality requested but supportAudio is false',
        );
      }
    }

    // Resolved before anything loads: values it rejects must not fetch a
    // model or open its reader. A `.task` file carries no sampler, so an unset
    // field comes from the family defaults. MediaPipe web 0.10.30 has no topP
    // option; it is passed and dropped.
    final sampling = resolveMediaPipeSampling(
      SamplingParams(
        temperature: temperature,
        topK: topK,
        topP: topP,
        randomSeed: randomSeed,
      ),
      modelType: modelType,
    );
    if (topP != null && !_topPIgnoredWarned) {
      _topPIgnoredWarned = true;
      // Printed, because a release build is where it gets reported and
      // edgeAiLog is silent there.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_mediapipe] WARNING: topP is ignored: MediaPipe web '
        'has no top-p. Shown once.',
      );
    }
    return sampling;
  }

  WebModelSession _newSession(
    LlmInference llm, {
    required String? systemInstruction,
    required VoidCallback onClose,
  }) => WebModelSession(
    backend: _backend ??= LlmInferenceBackend(llm),
    modelType: modelType,
    fileType: fileType,
    supportImage: supportImage, // Enabling image support
    supportAudio: supportAudio, // Enabling audio support
    systemInstruction: systemInstruction,
    template: _template,
    maxImages: supportImage ? (maxNumImages ?? 1) : null,
    onClose: onClose,
  );

  /// A session of its own over the one loaded model: its conversation is its
  /// own, and each of its turns sends that whole conversation. The sessions
  /// share the model's `LlmInference`, so their calls run one at a time, in
  /// the order they were made; a stop or a close ends only this session's
  /// call. The sampling and LoRA are the model's: the first session that
  /// loads it sets them, as for [createSession], and a later one that asks
  /// for others is told once (printed).
  @override
  Future<InferenceModelSession> openEngineSession(
    SessionRequest request,
  ) async {
    _requireOpen();
    final cap = maxConcurrentSessions;
    if (cap != null && _openSessions.length + _openingSessions >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one.',
      );
    }
    final sampling = _sessionSampling(
      temperature: request.temperature,
      randomSeed: request.randomSeed,
      topK: request.topK,
      topP: request.topP,
      enableVisionModality: request.enableVisionModality,
      enableAudioModality: request.enableAudioModality,
      enableThinking: request.enableThinking,
      maxOutputTokens: request.maxOutputTokens,
    );
    final LlmInference llm;
    _openingSessions++;
    try {
      llm = await _loadModel(
        sampling,
        request.loraPath,
        explicit:
            request.temperature != null ||
            request.topK != null ||
            request.randomSeed != null,
      );
    } finally {
      _openingSessions--;
    }
    // Closed while it loaded: close() has already released what it had, so
    // a session built now would sit on a model that is gone.
    if (_isClosed) {
      throw StateError('The model was closed while it was loading.');
    }
    late final WebModelSession session;
    session = _newSession(
      llm,
      systemInstruction: request.systemInstruction,
      onClose: () => _openSessions.remove(session),
    );
    _openSessions.add(session);
    return session;
  }

  /// Ends when the [createSession] call before the current one has returned.
  Future<void> _sessionLane = Future<void>.value();

  void _requireOpen() {
    if (_isClosed) throw StateError('The model is closed.');
  }

  /// Loads the model once; callers that arrive while it loads share the load.
  /// The sampling and LoRA of the first session are the ones the model keeps:
  /// MediaPipe sets them on the `LlmInference`, which every session shares. A
  /// later session that asks for others is told once per model.
  Future<LlmInference> _loadModel(
    ResolvedSampling sampling,
    String? loraPath, {
    required bool explicit,
  }) async {
    var pending = _llmFuture;
    if (pending == null) {
      pending = _llmFuture = _createModel(sampling, loraPath);
      _loadedWith = (
        sampling: sampling,
        explicit: explicit,
        loraPath: loraPath,
      );
    } else {
      _warnIfIgnored(sampling, loraPath, explicit: explicit);
    }
    try {
      return await pending;
    } catch (_) {
      if (identical(_llmFuture, pending)) {
        _llmFuture = null;
        _loadedWith = null;
      }
      rethrow;
    }
  }

  /// What the loaded model was created with.
  ({ResolvedSampling sampling, bool explicit, String? loraPath})? _loadedWith;
  bool _ignoredWarned = false;

  /// Prints once per model when a later session asks for a sampling or a
  /// LoRA other than the loaded ones, and the caller chose either side. topP
  /// is left out: MediaPipe web has none, which is said on its own.
  void _warnIfIgnored(
    ResolvedSampling sampling,
    String? loraPath, {
    required bool explicit,
  }) {
    final loaded = _loadedWith;
    if (loaded == null || _ignoredWarned) return;
    String describe(ResolvedSampling s) =>
        'temperature ${s.temperature}, topK ${s.topK}, randomSeed '
        '${s.randomSeed}';
    final asked = <String>[];
    final kept = <String>[];
    final other = loaded.sampling;
    if ((explicit || loaded.explicit) &&
        (other.temperature != sampling.temperature ||
            other.topK != sampling.topK ||
            other.randomSeed != sampling.randomSeed)) {
      asked.add(describe(sampling));
      kept.add(describe(other));
    }
    if (loraPath != null && loraPath != loaded.loraPath) {
      asked.add('LoRA $loraPath');
      kept.add(loaded.loraPath == null ? 'no LoRA' : 'LoRA ${loaded.loraPath}');
    }
    if (asked.isEmpty) return;
    _ignoredWarned = true;
    // Printed, because a release build is where it gets reported and
    // edgeAiLog is silent there.
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_mediapipe] WARNING: a session asks for '
      '${asked.join('; ')}, but every session of this web model shares the '
      'LlmInference loaded with ${kept.join('; ')}. Close and reload the '
      'model to change it. Shown once per model.',
    );
  }

  Future<LlmInference> _createModel(
    ResolvedSampling sampling,
    String? loraPath,
  ) async {
    // Shared resolver handles activeModel lookup + storage-mode branch.
    // Used identically by the LiteRT-LM web model in flutter_edge_ai_litertlm.
    final resolved = await sourceResolver.resolveActiveInferenceModel();

    _template = await resolveWebChatTemplate(
      readPrefix: () =>
          readModelPrefix(resolved.model, taskMetadataPrefixBytes),
      modelType: modelType,
    );

    final fileset = await FilesetResolver.forGenAiTasks(
      'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.30/wasm'.toJS,
    ).toDart;

    // LoRA path comes from the resolver alongside the model source.
    final loraPathToUse = loraPath ?? resolved.loraPath;
    final hasLoraParams = loraPathToUse != null && loraRanks != null;

    // MediaPipe consumes either modelAssetPath (Blob URL string) or
    // modelAssetBuffer (ReadableStreamDefaultReader, for OPFS streaming).
    final baseOptions = switch (resolved.model) {
      BlobUrlModelSource(:final url) => LlmInferenceBaseOptions(
        modelAssetPath: url,
      ),
      OpfsStreamModelSource() => LlmInferenceBaseOptions(
        modelAssetBuffer: await (resolved.model as OpfsStreamModelSource)
            .openReader(),
      ),
    };

    final config = LlmInferenceOptions(
      baseOptions: baseOptions,
      maxTokens: maxTokens,
      randomSeed: sampling.randomSeed,
      topK: sampling.topK,
      temperature: sampling.temperature,
      topP: sampling.topP,
      supportedLoraRanks: !hasLoraParams
          ? null
          : Int32List.fromList(loraRanks!).toJS,
      loraPath: !hasLoraParams ? null : loraPathToUse,
      maxNumImages: supportImage ? (maxNumImages ?? 1) : null,
    );

    return LlmInference.createFromOptions(fileset, config).toDart;
  }

  /// The teardown in progress, shared by every caller of [close]: a second
  /// call waits for it instead of returning at once, so core can tell when
  /// the model is really gone before it builds the next one.
  Future<void>? _closeFuture;

  @override
  Future<void> close() {
    final teardown = _closeFuture;
    if (teardown != null) return teardown;
    final settled = Completer<void>();
    _closeFuture = settled.future;
    // The first caller gets the teardown's own outcome; every later caller
    // gets `settled`, which completes normally once the teardown has ended.
    return _close().whenComplete(settled.complete);
  }

  Future<void> _close() async {
    _isClosed = true;
    await session?.close();
    session = null;
    // A copy: each close removes its session from the set.
    for (final open in _openSessions.toList()) {
      await open.close();
    }
    // Cleanup MediaPipe LlmInference WASM resources (important for hot restart)
    // This prevents memory leaks and "memory access out of bounds" errors
    // Note: MediaPipe's close() will also release any OPFS stream readers internally
    final loading = _llmFuture;
    _llmFuture = null;
    _backend = null;
    if (loading != null) {
      try {
        (await loading).close();
        if (kDebugMode) {
          edgeAiLog('[WebInferenceModel] Cleaned up LlmInference resources');
        }
      } catch (e) {
        if (kDebugMode) {
          edgeAiLog(
            '[WebInferenceModel] Warning: Error closing LlmInference: $e',
          );
        }
      }
    }
    onClose();
    fireCloseListeners();
  }
}
