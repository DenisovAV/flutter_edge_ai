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

  /// Cap on concurrent [openSession] sessions; null = unlimited. Accepted
  /// for API symmetry. The MediaPipe web `.task` path doesn't support
  /// concurrent sessions yet (openSession inherits the interface's
  /// UnsupportedError), so this is currently informational.
  final int? maxConcurrentSessions;

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

    // One call at a time from here on. Two calls that arrive during the first
    // load both continue when it ends; the second would close the session the
    // first is about to return.
    final turn = _sessionLane;
    final done = Completer<void>();
    _sessionLane = done.future;
    try {
      await turn;
      final llm = await _loadModel(sampling, loraPath);

      // Like the mobile model: a new session closes the one before it and
      // starts a clean conversation. MediaPipe web keeps nothing between
      // calls, so the conversation lives in the session, and a session that
      // outlived its chat would carry that chat into the next one.
      if (session case final previous?) {
        await previous.close();
      }
      return session = WebModelSession(
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
    } finally {
      done.complete();
    }
  }

  /// Ends when the [createSession] call before the current one has returned.
  Future<void> _sessionLane = Future<void>.value();

  /// Loads the model once; callers that arrive while it loads share the load.
  /// The sampling of the first session is the one the model keeps, as on every
  /// engine (LiteRT-LM#2080).
  Future<LlmInference> _loadModel(
    ResolvedSampling sampling,
    String? loraPath,
  ) async {
    final pending = _llmFuture ??= _createModel(sampling, loraPath);
    try {
      return await pending;
    } catch (_) {
      if (identical(_llmFuture, pending)) _llmFuture = null;
      rethrow;
    }
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
