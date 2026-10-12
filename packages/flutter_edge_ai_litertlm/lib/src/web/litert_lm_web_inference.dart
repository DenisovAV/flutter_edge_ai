// Standalone library: the web `.litertlm` inference model + session. Lives in
// flutter_edge_ai_litertlm (extracted from core's flutter_edge_ai_web.dart). Imports
// the shared web infra (web_model_source) and core parsing
// directly so it no longer needs to be a `part of flutter_edge_ai_web.dart`.
import 'dart:async';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';

import 'litert_lm_page_lock.dart';
import 'litert_lm_web.dart';
import '../ffi/engine_sampler_latch.dart';
import '../thinking_context.dart';
import 'litert_lm_web_session_config.dart';

/// Web `.litertlm` inference via the upstream `@litert-lm/core` early-preview
/// JS API (`@litert-lm/core` 0.18.0 on web through WebGPU/WASM).
///
/// Mirrors [FfiInferenceModel] (mobile/desktop) for the same C API but maps
/// it onto the JS surface: `Engine.create` → `engine.createConversation` →
/// `conversation.sendMessageStreaming(text)` returning a JS AsyncIterator.
///
/// **Limitations (matches upstream early-preview status):**
/// - Text-in/text-out only. An image or audio message throws
///   [UnsupportedError] from [LiteRtLmWebSession.addQueryChunk], because the
///   JS API creates the LLM engine with no vision or audio executor (see
///   [createSession]).
/// - Thinking reaches the model as `extra_context` with an explicit
///   `enable_thinking` ([thinkingContext]), the key the chat templates read —
///   measured on Gemma 4 E2B in Chrome (`web_thinking_test.dart`). The earlier
///   `{thinking: true}` reached no template, which is why web thinking was
///   once documented as unsupported.
/// - LoRA throws [UnsupportedError] (parity with FFI path).
/// - `stopGeneration()` closes the local stream and calls the upstream
///   `conversation.cancel()` to abort the JS-side generation (wrapped in
///   try/catch — the early-preview API may throw if nothing is in flight).
/// - For models >2 GB use `WebStorageMode.streaming` so the resolver returns
///   an [OpfsStreamModelSource] — passing a Blob URL to `Engine.create`
///   trips Chrome's `ERR_BLOB_OUT_OF_MEMORY` limit. The
///   [WebModelSourceResolver] handles the routing transparently — same path
///   MediaPipe `WebInferenceModel` uses today.
class LiteRtLmWebInferenceModel extends InferenceModel with CloseNotifier {
  LiteRtLmWebInferenceModel({
    required this.sourceResolver,
    required this.maxTokens,
    required this.modelType,
    this.fileType = ModelFileType.litertlm,
    this.maxConcurrentSessions,
    required this.onClose,
  });

  /// Shared with [WebInferenceModel] — resolves the active model into either
  /// a [BlobUrlModelSource] (cacheApi/none) or [OpfsStreamModelSource]
  /// (streaming). Engine-specific glue lives in [_ensureEngine] below.
  final WebModelSourceResolver sourceResolver;
  final ModelType modelType;
  @override
  final ModelFileType fileType;
  @override
  final int maxTokens;
  @override
  PreferredBackend? get activeBackend => null;

  /// Cap on concurrent [openSession] sessions; null = unlimited.
  final int? maxConcurrentSessions;
  final VoidCallback onClose;

  LiteRtLmEngine? _engine;
  LiteRtLmWebSession? _session;
  Completer<InferenceModelSession>? _createCompleter;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  /// Guards [_ensureEngine] against concurrent calls. Without it, two
  /// overlapping openSession/createSession calls both see `_engine == null`
  /// and both call `Engine.create`, leaking the first engine (JS/WASM + GPU
  /// resources) for the page lifetime.
  Completer<void>? _engineCompleter;

  /// Serializes generation across all sessions on this model — concurrent
  /// contexts, serialized inference, matching the FFI/MediaPipe paths. The
  /// `@litert-lm/core` engine is shared WebGPU/WASM state; parallel
  /// generations would contend for the accelerator. Passed to each session.
  final Mutex generationMutex = Mutex();

  /// Sessions opened via [openSession] — detached from the legacy [_session]
  /// singleton. Each owns its own `@litert-lm/core` Conversation JS object.
  final Set<LiteRtLmWebSession> _openSessions = {};

  @override
  InferenceModelSession? get session => _session;

  @override
  List<InferenceModelSession> get sessions =>
      List.unmodifiable([if (_session != null) _session!, ..._openSessions]);

  Future<void> _ensureEngine() async {
    if (_engine != null) return;
    // Concurrent-call guard: a second caller awaits the first creation instead
    // of starting its own (which would leak an engine).
    if (_engineCompleter != null) {
      await _engineCompleter!.future;
      return;
    }
    final completer = _engineCompleter = Completer<void>();
    try {
      await _createEngine();
      completer.complete();
    } catch (e, st) {
      _engineCompleter = null; // allow retry
      completer.completeError(e, st);
      rethrow;
    }
  }

  Future<void> _createEngine() async {
    final resolved = await sourceResolver.resolveActiveInferenceModel();

    // The host page wires up `window.litertLmReady` (a Promise resolving to
    // the Engine constructor) in its index.html `<script type="module">`
    // block. Module scripts are deferred, so Dart can reach here before the
    // ESM finishes loading and `window.Engine` would be undefined. Awaiting
    // the readiness promise guarantees the @litert-lm/core module is loaded
    // before any static interop call on `LiteRtLmEngine`.
    final ready = globalContext.getProperty<JSObject?>('litertLmReady'.toJS);
    if (ready == null) {
      throw StateError(
        'window.litertLmReady is not set. The host page must include the '
        '@litert-lm/core ESM loader from example/web/index.html — see '
        'README "Web .litertlm setup".',
      );
    }
    await (ready as JSPromise).toDart;

    final JSAny modelArg;
    final String diagDescription;
    switch (resolved.model) {
      case BlobUrlModelSource(:final url):
        modelArg = url.toJS;
        diagDescription = url;
      case OpfsStreamModelSource(:final filename):
        modelArg = await (resolved.model as OpfsStreamModelSource).openStream();
        diagDescription = '<OPFS ReadableStream: $filename>';
    }

    if (kDebugMode) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel] Engine.create({model: $diagDescription})',
      );
    }
    final sw = Stopwatch()..start();
    // Streams the model into the page's WebAssembly module, which the
    // EmbeddingGemma 2 engine shares: see litert_lm_page_lock.dart.
    _engine = await liteRtLmPageLock.run(
      () =>
          LiteRtLmEngine.create(LiteRtLmEngineOptions(model: modelArg)).toDart,
    );
    if (kDebugMode) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel/perf] Engine.create: ${sw.elapsedMilliseconds}ms',
      );
    }
  }

  @override
  Future<InferenceModelSession> createSession({
    double? temperature,
    int? randomSeed,
    int? topK,
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
        'LoRA weights are not supported on the .litertlm web path '
        '(loraPath=$loraPath). Track upstream @litert-lm/core; remove '
        'loraPath or use a MediaPipe .task web model.',
      );
    }
    // No vision or audio on web, as of @litert-lm/core 0.18.0. `Engine.create`
    // builds the LLM engine with `EngineSettings.createDefault(modelAssets,
    // backend)`, which takes no vision or audio backend — only the separate
    // `EmbeddingEngine` has `createDefaultMultimodal` — so the engine never
    // loads either executor. Measured on Gemma 4 E2B in Chrome 155 on Linux
    // (WebGPU on a Tesla T4) against the raw JS API, one conversation per
    // attempt:
    //   - `visionModalityEnabled` / `audioModalityEnabled: true` in the
    //     session config: `createConversation` throws "Vision options should
    //     not be null." / "Audio options should not be null.";
    //   - an image or audio content part with the typed `data` field (base64
    //     string or bytes): "Audio or image item must contain a path or
    //     blob." — only `EmbeddingEngine` converts `data`, a Conversation
    //     passes the message JSON to the runtime as it is;
    //   - the same part with the runtime's own `blob` field: "Vision executor
    //     should not be null, please TryLoadingVisionExecutor() first." (and
    //     the audio equivalent).
    // Text before and after those attempts still answered, so the engine
    // survives them. The modality flags are therefore not forwarded, and an
    // image or audio message throws in [LiteRtLmWebSession.addQueryChunk]
    // rather than being dropped, which left the model answering about media
    // it never received.
    _noteModalityRequested(enableVisionModality, enableAudioModality);
    // Resolved before anything loads: values it rejects must not load the
    // engine.
    final explicit = SamplingParams(
      temperature: temperature,
      topK: topK,
      topP: topP,
      randomSeed: randomSeed,
    );
    final sampling = _resolveSampling(explicit, thinking: enableThinking);

    if (_createCompleter case Completer<InferenceModelSession> completer) {
      return completer.future;
    }
    final completer = _createCompleter = Completer<InferenceModelSession>();
    final sessionSw = Stopwatch()..start();

    try {
      final conversation = await _buildConversation(
        sampling: sampling,
        systemInstruction: systemInstruction,
        enableThinking: enableThinking,
        tools: tools,
        maxOutputTokens: maxOutputTokens,
        sw: sessionSw,
      );

      final session = _session = LiteRtLmWebSession(
        conversation: conversation,
        modelType: modelType,
        fileType: fileType,
        generationMutex: generationMutex,
        onGeneration: () =>
            _noteGeneration(sampling, explicit: !explicit.isEmpty),
        onClose: () {
          _session = null;
          _createCompleter = null;
        },
      );

      completer.complete(session);
      if (kDebugMode) {
        edgeAiLog(
          '[LiteRtLmWebInferenceModel/perf] createSession total: ${sessionSw.elapsedMilliseconds}ms',
        );
      }
      return session;
    } catch (e, st) {
      completer.completeError(e, st);
      _createCompleter = null;
      rethrow;
    }
  }

  @override
  Future<InferenceModelSession> openSession({
    double? temperature,
    int? randomSeed,
    int? topK,
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
        'LoRA weights are not supported on the .litertlm web path. '
        'Remove loraPath or use a MediaPipe .task web model.',
      );
    }
    final cap = maxConcurrentSessions;
    if (cap != null && _openSessions.length >= cap) {
      throw StateError(
        'Max concurrent sessions ($cap) reached. Close an existing session '
        'before opening a new one.',
      );
    }
    // No vision or audio on web — see the comment in createSession.
    _noteModalityRequested(enableVisionModality, enableAudioModality);

    // Resolved before anything loads: values it rejects must not load the
    // engine.
    final explicit = SamplingParams(
      temperature: temperature,
      topK: topK,
      topP: topP,
      randomSeed: randomSeed,
    );
    final sampling = _resolveSampling(explicit, thinking: enableThinking);
    await _ensureEngine();
    final conversation = await _buildConversation(
      sampling: sampling,
      systemInstruction: systemInstruction,
      enableThinking: enableThinking,
      tools: tools,
      maxOutputTokens: maxOutputTokens,
      sw: Stopwatch()..start(),
    );

    late final LiteRtLmWebSession session;
    session = LiteRtLmWebSession(
      conversation: conversation,
      modelType: modelType,
      fileType: fileType,
      generationMutex: generationMutex,
      onGeneration: () =>
          _noteGeneration(sampling, explicit: !explicit.isEmpty),
      onClose: () => _openSessions.remove(session),
    );
    _openSessions.add(session);
    return session;
  }

  /// The web API cannot read a bundle's sampler, so an unset field comes from
  /// the family defaults; the models published for web (Gemma 4, Gemma 3n)
  /// ship no sampler of their own. Throws an [ArgumentError] for a value no
  /// engine can sample with.
  ResolvedSampling _resolveSampling(
    SamplingParams explicit, {
    required bool thinking,
  }) => SamplingParams.resolve(
    explicit,
    modelType: modelType,
    thinking: thinking,
  );

  /// The web engine runs the same LiteRT-LM runtime, so it too keeps the
  /// sampler of its first generation (google-ai-edge/LiteRT-LM#2080).
  final _samplerLatch = EngineSamplerLatch();

  /// Reports what LiteRT-LM#2080 means for a generation with [sampling], as
  /// the native client does.
  void _noteGeneration(ResolvedSampling sampling, {required bool explicit}) {
    final note = _samplerLatch.onGeneration(sampling, explicit: explicit);
    if (note == null) return;
    if (!note.warn) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel] ${note.message}',
        level: EdgeAiLogLevel.verbose,
      );
      return;
    }
    // A release build is where a wrong sampler gets reported, and edgeAiLog
    // is silent there.
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] WARNING: ${note.message} Shown once per '
      'engine.',
    );
  }

  /// Says, in debug builds, that a requested vision/audio modality will not be
  /// honoured. The session still opens: a text-only conversation is valid,
  /// and an app that passes `supportImage: true` on every platform should keep
  /// working on web for text. The media message itself is what throws.
  void _noteModalityRequested(bool? vision, bool? audio) {
    if (kDebugMode && (vision == true || audio == true)) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel] Warning: vision/audio modality was '
        'requested, but web LiteRT-LM runs LLMs text-only; an image or audio '
        'message will throw UnsupportedError.',
      );
    }
  }

  /// Builds an `@litert-lm/core` Conversation from sampler + preface config.
  /// Shared by [createSession] (legacy singleton) and [openSession]
  /// (detached) so the JS interop and tool/thinking wiring stay in one place.
  Future<LiteRtLmConversation> _buildConversation({
    required ResolvedSampling sampling,
    String? systemInstruction,
    required bool enableThinking,
    required List<Tool> tools,
    required Stopwatch sw,
    int? maxOutputTokens,
  }) async {
    await _ensureEngine();

    // Build SessionConfig matching upstream TS (see [webSessionConfig]).
    final sessionConfigMap = webSessionConfig(
      sampling,
      maxOutputTokens: maxOutputTokens,
    );
    final sessionConfigJs = sessionConfigMap.jsify() as JSObject?;

    // Build Preface matching upstream TS:
    //   { messages?: Message[], tools?: Tool[], extra_context?: {...} }
    final prefaceMessages = <Map<String, Object>>[];
    if (systemInstruction != null && systemInstruction.isNotEmpty) {
      prefaceMessages.add(<String, Object>{
        'role': 'system',
        'content': systemInstruction,
      });
    }
    // Tools — for the models whose tool calling LiteRT-LM runs natively (Gemma
    // 4, and FunctionGemma), the same predicate as the native FFI path in
    // `FfiInferenceModel`. Reuses [SdkResponseParser.serializeToolsForSdk] so
    // the JSON shape is byte-identical between web and native.
    final toolsForPreface =
        tools.isNotEmpty &&
            FunctionCallParser.usesSdkPassthrough(modelType, fileType: fileType)
        ? (jsonDecode(SdkResponseParser.serializeToolsForSdk(tools))
              as List<dynamic>)
        : const <dynamic>[];
    final prefaceMap = <String, Object>{
      if (prefaceMessages.isNotEmpty) 'messages': prefaceMessages,
      if (toolsForPreface.isNotEmpty) 'tools': toolsForPreface,
      // The key the templates read, sent both ways — see [thinkingContext].
      'extra_context': thinkingContext(enableThinking),
    };
    final prefaceJs = prefaceMap.isNotEmpty
        ? prefaceMap.jsify() as JSObject
        : null;

    final beforeConv = sw.elapsedMilliseconds;
    final options = LiteRtLmConversationOptions(
      sessionConfig: sessionConfigJs,
      preface: prefaceJs,
      filterChannelContentFromKvCache: enableThinking ? true : null,
      // Deliberately NOT enabled, unlike the FFI path. Upstream
      // google-ai-edge/LiteRT-LM#2434: with constrained decoding on, the WASM
      // grammar does not return to its start state after a completed
      // `<|tool_call>...<tool_call|>` block, so the NEXT decode round in that
      // conversation aborts with `Invalid token at state N` no matter what it
      // contains. That kills every multi-turn tool flow — including the agent
      // loop's call -> result -> continue, which cannot avoid that round.
      //
      // Measured on 0.17.0, seven cases in
      // `example/integration_test/web_function_calling_test.dart`: with the
      // flag off all pass, including the negative control (a non-action prompt
      // still calls nothing) and the round-trip. Gemma 4 emits well-formed
      // tool-call blocks without the grammar, and `SdkResponseParser` keeps its
      // raw-token fallback for the case where it does not. With the flag on,
      // any turn following a tool call fails.
      //
      // Native keeps it on: the C++ grammar resets correctly and is
      // unaffected. Re-enable here once #2434 is fixed upstream.
      enableConstrainedDecoding: null,
    );
    final engine = _engine!;
    // May prefill the preface inside the page's WebAssembly module: see
    // litert_lm_page_lock.dart.
    final conversation = await liteRtLmPageLock.run(
      () => engine.createConversation(options).toDart,
    );
    if (kDebugMode) {
      edgeAiLog(
        '[LiteRtLmWebInferenceModel/perf] createConversation: ${sw.elapsedMilliseconds - beforeConv}ms',
      );
    }
    return conversation;
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
    try {
      await _session?.close();
      for (final s in _openSessions.toList()) {
        await s.close();
      }
      _openSessions.clear();
    } finally {
      try {
        _engine?.delete();
      } catch (e) {
        if (kDebugMode) {
          edgeAiLog('[LiteRtLmWebInferenceModel] engine.delete() failed: $e');
        }
      }
      _engine = null;
      onClose();
      fireCloseListeners();
    }
  }
}

/// Session-side accumulator + async iterator pump for `@litert-lm/core`.
///
/// Mirrors [FfiInferenceModelSession] (lib/src/ffi/ffi_inference_model.dart)
/// 1:1 — same buffering of query chunks, same Gemma 4 raw-JSON-accumulating
/// branch, same `with RawSdkResponseSession` mixin so [InferenceChat] reads
/// `lastRawResponse` and extracts `tool_calls` via the shared
/// [SdkResponseParser]. The only platform-specific bit is that here the JS
/// AsyncIterator is driven manually via [LiteRtLmAsyncIter.next] rather than
/// a Dart `Stream` from native FFI.
class LiteRtLmWebSession extends InferenceModelSession
    with RawSdkResponseSession {
  LiteRtLmWebSession({
    required this.conversation,
    required this.modelType,
    required this.fileType,
    required this.generationMutex,
    required this.onClose,
    this.onGeneration,
  });

  final LiteRtLmConversation conversation;
  final ModelType modelType;
  final ModelFileType fileType;

  /// Shared across all sessions of the owning model — serializes generation
  /// (concurrent contexts, serialized inference). Acquired for the whole
  /// duration of a getResponse(Async) call.
  final Mutex generationMutex;
  final VoidCallback onClose;

  /// Called after each message is sent, for the owning model's sampler latch.
  final VoidCallback? onGeneration;

  final StringBuffer _queryBuffer = StringBuffer();
  bool _isClosed = false;
  bool _isCancelled = false;

  /// Completes when the generation that started last has read its JS stream
  /// to the end and released its page lease; null before the first one.
  /// [close] waits for it, so the owning model deletes its engine only after
  /// nothing is suspended inside the page's WebAssembly module any more.
  Future<void>? _generationEnded;

  /// Releases that generation's page lease. [close] calls it when the stream
  /// does not end within [closeDrainTimeout], so a stuck runtime cannot hold
  /// the page lock (and with it every EmbeddingGemma 2 call) for good.
  void Function()? _releaseGenerationPage;

  /// How long [close] waits for a cancelled generation to end.
  static const Duration closeDrainTimeout = Duration(seconds: 30);

  /// Whether LiteRT-LM runs this model's tool calling natively (Gemma 4, and
  /// FunctionGemma); see [FunctionCallParser.usesSdkPassthrough].
  late final bool _nativeTools = FunctionCallParser.usesSdkPassthrough(
    modelType,
    fileType: fileType,
  );

  /// Tool results staged since the last generation, for [_nativeTools] models.
  final List<({String name, Object? response})> _pendingToolResponses = [];

  /// Whether anything other than a tool result was staged for this turn.
  bool _stagedNonToolContent = false;

  /// Last full raw JSON response from SDK — native tool models only.
  /// chat.dart reads it via [lastRawResponse] and runs
  /// [SdkResponseParser.extractToolCalls] on it before falling back to text
  /// extraction. Mirrors [FfiInferenceModelSession._lastRawResponse].
  String? _lastRawResponse;

  @override
  String? get lastRawResponse => _lastRawResponse;

  /// JS `JSON.stringify` handle, looked up once per session.
  late final JSObject _jsJson = globalContext.getProperty<JSObject>(
    'JSON'.toJS,
  );

  String _stringifyChunk(JSObject value) =>
      _jsJson.callMethod<JSString>('stringify'.toJS, value).toDart;

  void _assertNotClosed() {
    if (_isClosed) throw StateError('Session is closed');
  }

  /// The error for an image or audio message. The engine has no vision or
  /// audio executor (see [LiteRtLmWebInferenceModel.createSession]), so the
  /// bytes could reach no encoder; dropping them instead let the model answer
  /// about media it never received.
  static UnsupportedError _unsupportedMedia(Message message) {
    final kinds = [
      if (message.hasImage) 'image',
      if (message.hasAudio) 'audio',
    ].join(' and ');
    return UnsupportedError(
      'Web LiteRT-LM does not support $kinds input for LLMs yet: '
      '@litert-lm/core 0.18.0 creates the LLM engine without a vision or '
      'audio executor. Send text only to a web .litertlm model'
      '${message.hasImage ? ', or use a MediaPipe .task web model for images' : ''}.',
    );
  }

  /// Stages [message] for the next generation. Throws [UnsupportedError] for
  /// a message with an image or audio, before anything is staged, so the
  /// rejected message leaves the next turn unchanged.
  @override
  Future<void> addQueryChunk(Message message) async {
    _assertNotClosed();
    if (message.hasImage || message.hasAudio) {
      throw _unsupportedMedia(message);
    }
    final prompt = message.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    _queryBuffer.write(prompt);
    if (_nativeTools && message.type == MessageType.toolResponse) {
      final name = message.toolName;
      if (name == null) {
        throw ArgumentError.value(
          message,
          'message',
          'A tool response needs toolName: the runtime formats the result as '
              'response:NAME{...}, and without a name it answers no call',
        );
      }
      _pendingToolResponses.add((
        name: name,
        response: SdkResponseParser.toolResponsePayload(message.text),
      ));
    } else if (prompt.isNotEmpty) {
      _stagedNonToolContent = true;
    }
  }

  /// The staged tool results as one role-`tool` message, when they are the
  /// whole turn; mirrors `FfiInferenceModelSession`. A turn that also carries
  /// user text is a user message, and the results stay in its text.
  String? _takeToolResponseMessage() {
    final onlyTools =
        _pendingToolResponses.isNotEmpty && !_stagedNonToolContent;
    final message = onlyTools
        ? SdkResponseParser.buildToolResponsesJson(_pendingToolResponses)
        : null;
    _pendingToolResponses.clear();
    _stagedNonToolContent = false;
    return message;
  }

  @override
  Future<String> getResponse() async {
    _assertNotClosed();
    final buf = StringBuffer();
    await for (final chunk in getResponseAsync()) {
      buf.write(chunk);
    }
    return buf.toString();
  }

  @override
  Stream<String> getResponseAsync() {
    _assertNotClosed();
    final text = _queryBuffer.toString();
    _queryBuffer.clear();
    _isCancelled = false;
    final toolMessage = _takeToolResponseMessage();

    final controller = StreamController<String>();
    final genSw = Stopwatch()..start();
    int? firstChunkMs;
    var chunkCount = 0;

    // Serialize generation across all sessions of this model. Acquired before
    // the pump starts (in onListen) and released exactly once in every
    // terminal path (done / error / consumer cancel) so an abandoned stream
    // can't hold the lock forever.
    var mutexHeld = false;
    var released = false;
    void releaseMutex() {
      if (released) return;
      released = true;
      if (mutexHeld) generationMutex.release();
    }

    // The page lock (litert_lm_page_lock.dart): held from before
    // `sendMessageStreaming` until the JS stream has ENDED — not until the
    // Dart consumer stops listening. A generation stays suspended inside the
    // page's WebAssembly module for its whole length, and the EmbeddingGemma 2
    // engine must not enter the module meanwhile. A consumer that cancels
    // early therefore leaves the pump draining the stream to its end.
    LiteRtLmPageLease? pageLease;
    final ended = Completer<void>();
    void releasePage() {
      pageLease?.release();
      if (!ended.isCompleted) ended.complete();
    }

    // The request payload: tool results go back as one role-`tool` message,
    // the only shape after which the template continues the model's own turn;
    // everything else is the staged text as a plain string (media never gets
    // this far — addQueryChunk refuses it).
    final JSAny messageArg = toolMessage != null
        ? (jsonDecode(toolMessage) as Map<String, Object?>).jsify() as JSAny
        : text.toJS;
    // Native tool models mirror FfiInferenceModelSession.getResponseAsync —
    // every raw chunk is stringified and appended to rawBuffer so chat.dart
    // can run SdkResponseParser.extractToolCalls on the assembled JSON. Other
    // model types skip accumulation and `_lastRawResponse` stays null.
    final accumulateRaw = _nativeTools;
    final rawBuffer = accumulateRaw ? StringBuffer() : null;
    if (accumulateRaw) {
      _lastRawResponse = null;
    }

    void startPump() {
      final raw = conversation.sendMessageStreaming(messageArg);
      onGeneration?.call();
      final asyncIterSym = globalContext
          .getProperty<JSObject>('Symbol'.toJS)
          .getProperty<JSAny>('asyncIterator'.toJS);
      final factory = raw.getProperty<JSFunction?>(asyncIterSym);
      final iter = factory != null
          ? raw.callMethod<JSObject>(asyncIterSym)
          : raw; // assume it's already an iterator

      // After the consumer is gone: reads the stream to its end, emitting
      // nothing, and only then lets the next page-lock holder in.
      void drain() {
        iter.next().toDart.then((JSObject step) {
          if (step.getProperty<JSBoolean>('done'.toJS).toDart) {
            releasePage();
          } else {
            drain();
          }
        }, onError: (Object _, StackTrace _) => releasePage());
      }

      void pump() {
        if (controller.isClosed || _isCancelled) {
          releaseMutex();
          if (!controller.isClosed) controller.close();
          drain();
          return;
        }
        iter.next().toDart.then(
          (JSObject step) {
            final done = (step.getProperty<JSBoolean>('done'.toJS)).toDart;
            if (controller.isClosed || _isCancelled) {
              releaseMutex();
              if (!controller.isClosed) controller.close();
              if (done) {
                releasePage();
              } else {
                drain();
              }
              return;
            }
            if (done) {
              if (accumulateRaw) {
                _lastRawResponse = rawBuffer!.toString();
              }
              if (kDebugMode) {
                final total = genSw.elapsedMilliseconds;
                edgeAiLog(
                  '[LiteRtLmWebSession/perf] generation total: ${total}ms '
                  '(prefill ${firstChunkMs ?? 0}ms, $chunkCount chunks)',
                );
              }
              releaseMutex();
              releasePage();
              controller.close();
              return;
            }
            if (firstChunkMs == null) {
              firstChunkMs = genSw.elapsedMilliseconds;
              if (kDebugMode) {
                edgeAiLog(
                  '[LiteRtLmWebSession/perf] time-to-first-chunk: ${firstChunkMs}ms',
                );
              }
            }
            chunkCount++;
            final value = step.getProperty<JSObject?>('value'.toJS);
            if (value != null) {
              // Stringify the JS chunk into the same JSON shape liblitert_lm
              // streams via the native FFI callback. Both engines then dump it
              // into the shared SdkTextExtractor — single source of truth for
              // text-vs-thinking extraction, identical to ffi_inference_model.dart.
              final jsonStr = _stringifyChunk(value);
              if (accumulateRaw) {
                rawBuffer!.write(jsonStr);
              }
              try {
                final text = SdkTextExtractor.extractTextFromResponse(jsonStr);
                if (text.isNotEmpty) controller.add(text);
              } catch (e, st) {
                releaseMutex();
                if (!controller.isClosed) {
                  controller.addError(e, st);
                  controller.close();
                }
                // The generation itself goes on: read it to its end.
                drain();
                return;
              }
            }
            pump();
          },
          onError: (Object error, StackTrace st) {
            releaseMutex();
            releasePage();
            if (!controller.isClosed) {
              controller.addError(error, st);
              controller.close();
            }
          },
        );
      }

      pump();
    }

    // Acquire the model-wide generation mutex before kicking off generation,
    // so concurrent sessions take turns (serialized inference). Released in
    // every terminal path (done / error / cancel) via releaseMutex().
    controller.onListen = () async {
      try {
        await generationMutex.acquire();
        mutexHeld = true;
        pageLease = await liteRtLmPageLock.acquire();
        if (_isCancelled || controller.isClosed) {
          releaseMutex();
          releasePage();
          if (!controller.isClosed) await controller.close();
          return;
        }
        // From here the stream holds the page until it ends; close() waits
        // for that (a generation still queued above has nothing to wait for).
        _generationEnded = ended.future;
        _releaseGenerationPage = releasePage;
        startPump();
      } catch (e, st) {
        // Nothing reached the stream's end if startPump threw: no drain.
        releasePage();
        releaseMutex();
        if (!controller.isClosed) {
          controller.addError(e, st);
          await controller.close();
        }
      }
    };
    controller.onCancel = () {
      _isCancelled = true;
      releaseMutex();
    };
    return controller.stream;
  }

  /// Approximate token count. `@litert-lm/core` (early preview) exposes no
  /// tokenizer, so unlike the FFI arm — which now asks the model's own — this
  /// can only estimate.
  ///
  /// Two characters per token, not four, for the same reason the FFI arm's
  /// fallback uses it: undercounting overruns the native KV cache, while
  /// overcounting only trims history early. Four was measured at 0.44x on
  /// Chinese against gemma-4-E2B-it, i.e. wrong in the crash direction.
  @override
  Future<int> sizeInTokens(String text) async => (text.length / 2).ceil();

  /// Stops the in-flight generation both locally (closes the Dart stream)
  /// and upstream (calls `conversation.cancel()` per the @litert-lm/core JS
  /// API). The cancel call is wrapped in try/catch because the early-preview
  /// API may throw if no generation is in flight.
  @override
  Future<void> stopGeneration() async {
    _isCancelled = true;
    try {
      conversation.cancel();
    } catch (e) {
      if (kDebugMode) {
        edgeAiLog('[LiteRtLmWebSession] conversation.cancel() threw: $e');
      }
    }
  }

  /// LiteRT-LM web does not surface benchmark info; return empty metrics.
  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {
    _isClosed = true;
    _isCancelled = true;
    // Abort any in-flight JS generation BEFORE the model tears the engine
    // down. Without this, the model's close() → engine.delete() can free the
    // WASM/WebGPU state while a pending iter.next() Promise is still resolving
    // against this conversation (use-after-free). stopGeneration() does the
    // same; close() must too.
    try {
      conversation.cancel();
    } catch (e) {
      if (kDebugMode) {
        edgeAiLog('[LiteRtLmWebSession] cancel during close threw: $e');
      }
    }
    // cancel() only asks the stream to stop: the pump keeps reading it to its
    // end and holds the page lock until then. Wait for that, so the model
    // deletes its engine after the last call into the module has returned.
    final ended = _generationEnded;
    if (ended != null) {
      await ended.timeout(
        closeDrainTimeout,
        onTimeout: () {
          edgeAiLog(
            '[LiteRtLmWebSession] the cancelled generation did not end within '
            '${closeDrainTimeout.inSeconds} s; releasing the page lock anyway.',
          );
          _releaseGenerationPage?.call();
        },
      );
    }
    _queryBuffer.clear();
    onClose();
  }
}
